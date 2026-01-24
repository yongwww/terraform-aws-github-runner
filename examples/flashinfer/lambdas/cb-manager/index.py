"""
CB Manager Lambda - Manages AWS Capacity Block reservations for FlashInfer CI

This Lambda handles:
1. Checking for active Capacity Blocks
2. Purchasing new CBs when needed
3. Tracking CB state in SSM
4. Preventing duplicate purchases (race condition handling)

Triggers:
- EventBridge scheduled rule (periodic check)
- Manual invocation for on-demand purchase
- Scale-up failure event (future)
"""

import boto3
import json
import logging
import os
from datetime import datetime, timedelta, timezone
from typing import Optional, Dict, Any, List

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# AWS clients
ec2 = boto3.client('ec2')
ssm = boto3.client('ssm')

# Configuration from environment
INSTANCE_TYPE = os.environ.get('INSTANCE_TYPE', 'p6-b200.48xlarge')
DURATION_HOURS = int(os.environ.get('DURATION_HOURS', '24'))
AVAILABILITY_ZONE = os.environ.get('AVAILABILITY_ZONE', '')  # Empty = auto-detect from VPC
SSM_PREFIX = os.environ.get('SSM_PREFIX', '/flashinfer/capacity-blocks')
SUBNET_IDS = os.environ.get('SUBNET_IDS', '').split(',')  # For AZ detection


def get_subnet_availability_zones() -> List[str]:
    """Get availability zones from configured subnets."""
    if not SUBNET_IDS or SUBNET_IDS == ['']:
        return []

    try:
        response = ec2.describe_subnets(SubnetIds=SUBNET_IDS)
        azs = list(set(subnet['AvailabilityZone'] for subnet in response['Subnets']))
        logger.info(f"Detected AZs from subnets: {azs}")
        return azs
    except Exception as e:
        logger.error(f"Failed to get AZs from subnets: {e}")
        return []


def get_active_capacity_blocks(instance_type: str, availability_zone: Optional[str] = None) -> List[Dict]:
    """
    Find active Capacity Block reservations for the given instance type.

    Returns list of active CBs with their details.
    """
    filters = [
        {'Name': 'instance-type', 'Values': [instance_type]},
        {'Name': 'state', 'Values': ['active', 'pending', 'payment-pending']},
    ]

    if availability_zone:
        filters.append({'Name': 'availability-zone', 'Values': [availability_zone]})

    try:
        # DescribeCapacityReservations returns both regular and capacity-block reservations
        # Filter for capacity-block by checking reservation-type or other attributes
        response = ec2.describe_capacity_reservations(Filters=filters)

        active_cbs = []
        for cr in response.get('CapacityReservations', []):
            # Check if this is a Capacity Block (has end date, typically)
            if cr.get('EndDate'):
                active_cbs.append({
                    'reservation_id': cr['CapacityReservationId'],
                    'state': cr['State'],
                    'instance_type': cr['InstanceType'],
                    'availability_zone': cr['AvailabilityZone'],
                    'available_capacity': cr.get('AvailableInstanceCount', 0),
                    'total_capacity': cr.get('TotalInstanceCount', 0),
                    'start_date': cr.get('StartDate'),
                    'end_date': cr.get('EndDate'),
                })

        logger.info(f"Found {len(active_cbs)} active Capacity Blocks for {instance_type}")
        return active_cbs

    except Exception as e:
        logger.error(f"Failed to describe capacity reservations: {e}")
        return []


def get_capacity_block_offerings(
    instance_type: str,
    duration_hours: int,
    availability_zone: Optional[str] = None
) -> List[Dict]:
    """
    Get available Capacity Block offerings that can be purchased.
    """
    try:
        # Calculate time window for CB start (next available)
        start_time = datetime.now(timezone.utc) + timedelta(minutes=5)
        end_time = start_time + timedelta(days=14)  # Look up to 2 weeks ahead

        params = {
            'InstanceType': instance_type,
            'InstanceCount': 1,
            'CapacityDurationHours': duration_hours,
            'StartDateRange': {
                'Earliest': start_time.isoformat(),
                'Latest': end_time.isoformat(),
            },
        }

        if availability_zone:
            params['AvailabilityZone'] = availability_zone

        response = ec2.describe_capacity_block_offerings(**params)

        offerings = []
        for offering in response.get('CapacityBlockOfferings', []):
            offerings.append({
                'offering_id': offering['CapacityBlockOfferingId'],
                'instance_type': offering['InstanceType'],
                'availability_zone': offering['AvailabilityZone'],
                'instance_count': offering['InstanceCount'],
                'start_date': offering['StartDate'],
                'end_date': offering['EndDate'],
                'duration_hours': offering['CapacityBlockDurationHours'],
                'upfront_fee': offering.get('UpfrontFee', 'unknown'),
            })

        logger.info(f"Found {len(offerings)} CB offerings for {instance_type}")
        return offerings

    except Exception as e:
        logger.error(f"Failed to get CB offerings: {e}")
        return []


def check_purchase_lock() -> bool:
    """
    Check if there's an active purchase lock (to prevent race conditions).
    Returns True if locked (purchase in progress), False if unlocked.
    """
    try:
        param_name = f"{SSM_PREFIX}/purchase-lock"
        response = ssm.get_parameter(Name=param_name)

        # Check if lock is expired (older than 10 minutes)
        lock_data = json.loads(response['Parameter']['Value'])
        lock_time = datetime.fromisoformat(lock_data['timestamp'])

        if datetime.now(timezone.utc) - lock_time > timedelta(minutes=10):
            logger.info("Purchase lock expired, clearing")
            ssm.delete_parameter(Name=param_name)
            return False

        logger.info(f"Purchase lock active, set at {lock_time}")
        return True

    except ssm.exceptions.ParameterNotFound:
        return False
    except Exception as e:
        logger.warning(f"Error checking purchase lock: {e}")
        return False


def set_purchase_lock() -> bool:
    """
    Set a purchase lock to prevent race conditions.
    Returns True if lock was acquired, False if already locked.
    """
    if check_purchase_lock():
        return False

    try:
        param_name = f"{SSM_PREFIX}/purchase-lock"
        lock_data = {
            'timestamp': datetime.now(timezone.utc).isoformat(),
            'instance_type': INSTANCE_TYPE,
        }

        ssm.put_parameter(
            Name=param_name,
            Value=json.dumps(lock_data),
            Type='String',
            Overwrite=True,
        )
        logger.info("Purchase lock acquired")
        return True

    except Exception as e:
        logger.error(f"Failed to set purchase lock: {e}")
        return False


def clear_purchase_lock():
    """Clear the purchase lock."""
    try:
        ssm.delete_parameter(Name=f"{SSM_PREFIX}/purchase-lock")
        logger.info("Purchase lock cleared")
    except ssm.exceptions.ParameterNotFound:
        pass
    except Exception as e:
        logger.warning(f"Error clearing purchase lock: {e}")


def purchase_capacity_block(offering_id: str) -> Optional[str]:
    """
    Purchase a Capacity Block from the given offering.
    Returns the reservation ID if successful, None otherwise.
    """
    try:
        response = ec2.purchase_capacity_block(
            CapacityBlockOfferingId=offering_id,
            InstancePlatform='Linux/UNIX',
            TagSpecifications=[
                {
                    'ResourceType': 'capacity-reservation',
                    'Tags': [
                        {'Key': 'Name', 'Value': f'flashinfer-{INSTANCE_TYPE}'},
                        {'Key': 'ManagedBy', 'Value': 'flashinfer-cb-manager'},
                        {'Key': 'Project', 'Value': 'FlashInfer-CI'},
                    ]
                }
            ]
        )

        reservation_id = response['CapacityReservation']['CapacityReservationId']
        logger.info(f"Purchased Capacity Block: {reservation_id}")

        # Store CB info in SSM for visibility
        store_cb_info(response['CapacityReservation'])

        return reservation_id

    except Exception as e:
        logger.error(f"Failed to purchase Capacity Block: {e}")
        return None


def store_cb_info(capacity_reservation: Dict):
    """Store Capacity Block info in SSM for visibility and tracking."""
    try:
        param_name = f"{SSM_PREFIX}/active-cb/{capacity_reservation['CapacityReservationId']}"
        cb_info = {
            'reservation_id': capacity_reservation['CapacityReservationId'],
            'instance_type': capacity_reservation['InstanceType'],
            'availability_zone': capacity_reservation['AvailabilityZone'],
            'state': capacity_reservation['State'],
            'start_date': capacity_reservation.get('StartDate', '').isoformat() if capacity_reservation.get('StartDate') else None,
            'end_date': capacity_reservation.get('EndDate', '').isoformat() if capacity_reservation.get('EndDate') else None,
            'purchased_at': datetime.now(timezone.utc).isoformat(),
        }

        ssm.put_parameter(
            Name=param_name,
            Value=json.dumps(cb_info, default=str),
            Type='String',
            Overwrite=True,
        )
        logger.info(f"Stored CB info in SSM: {param_name}")

    except Exception as e:
        logger.warning(f"Failed to store CB info in SSM: {e}")


def handler(event: Dict[str, Any], context) -> Dict[str, Any]:
    """
    Lambda handler for CB Manager.

    Event actions:
    - check: Check for active CBs, return status
    - ensure: Ensure a CB exists, purchase if needed
    - purchase: Force purchase a new CB
    - status: Get current CB status
    """
    logger.info(f"CB Manager invoked with event: {json.dumps(event)}")

    action = event.get('action', 'ensure')
    instance_type = event.get('instance_type', INSTANCE_TYPE)
    duration_hours = event.get('duration_hours', DURATION_HOURS)

    # Determine availability zone
    az = event.get('availability_zone', AVAILABILITY_ZONE)
    if not az:
        azs = get_subnet_availability_zones()
        az = azs[0] if azs else None

    logger.info(f"Action: {action}, Instance Type: {instance_type}, AZ: {az}")

    # Check for active CBs
    active_cbs = get_active_capacity_blocks(instance_type, az)

    if action == 'check' or action == 'status':
        return {
            'statusCode': 200,
            'action': action,
            'instance_type': instance_type,
            'availability_zone': az,
            'active_capacity_blocks': active_cbs,
            'has_active_cb': len(active_cbs) > 0,
        }

    if action == 'ensure':
        # If we have an active CB with capacity, we're good
        active_with_capacity = [cb for cb in active_cbs if cb['available_capacity'] > 0 and cb['state'] == 'active']

        if active_with_capacity:
            logger.info(f"Active CB with capacity exists: {active_with_capacity[0]['reservation_id']}")
            return {
                'statusCode': 200,
                'action': 'ensure',
                'result': 'exists',
                'capacity_block': active_with_capacity[0],
            }

        # Check if there's a pending CB
        pending_cbs = [cb for cb in active_cbs if cb['state'] in ['pending', 'payment-pending']]
        if pending_cbs:
            logger.info(f"CB purchase pending: {pending_cbs[0]['reservation_id']}")
            return {
                'statusCode': 200,
                'action': 'ensure',
                'result': 'pending',
                'capacity_block': pending_cbs[0],
            }

        # No active CB, need to purchase
        action = 'purchase'

    if action == 'purchase':
        # Acquire lock to prevent race conditions
        if not set_purchase_lock():
            logger.info("Another purchase is in progress, skipping")
            return {
                'statusCode': 200,
                'action': 'purchase',
                'result': 'locked',
                'message': 'Another purchase is in progress',
            }

        try:
            # Get available offerings
            offerings = get_capacity_block_offerings(instance_type, duration_hours, az)

            if not offerings:
                logger.warning(f"No CB offerings available for {instance_type} in {az}")
                return {
                    'statusCode': 404,
                    'action': 'purchase',
                    'result': 'no_offerings',
                    'message': f'No Capacity Block offerings available for {instance_type}',
                }

            # Select the earliest available offering
            offerings.sort(key=lambda x: x['start_date'])
            selected_offering = offerings[0]

            logger.info(f"Selected offering: {selected_offering['offering_id']}, "
                       f"starts: {selected_offering['start_date']}, "
                       f"fee: {selected_offering['upfront_fee']}")

            # Purchase the CB
            reservation_id = purchase_capacity_block(selected_offering['offering_id'])

            if reservation_id:
                return {
                    'statusCode': 200,
                    'action': 'purchase',
                    'result': 'purchased',
                    'reservation_id': reservation_id,
                    'offering': selected_offering,
                }
            else:
                return {
                    'statusCode': 500,
                    'action': 'purchase',
                    'result': 'failed',
                    'message': 'Failed to purchase Capacity Block',
                }

        finally:
            clear_purchase_lock()

    return {
        'statusCode': 400,
        'error': f'Unknown action: {action}',
    }
