import {
  CreateFleetCommand,
  CreateFleetResult,
  CreateTagsCommand,
  DeleteTagsCommand,
  DescribeCapacityReservationsCommand,
  DescribeInstancesCommand,
  DescribeInstancesResult,
  DescribeSubnetsCommand,
  EC2Client,
  FleetLaunchTemplateOverridesRequest,
  RunInstancesCommand,
  Tag,
  TerminateInstancesCommand,
  _InstanceType,
} from '@aws-sdk/client-ec2';
import { createChildLogger } from '@aws-github-runner/aws-powertools-util';
import { getTracedAWSV3Client, tracer } from '@aws-github-runner/aws-powertools-util';
import { getParameter } from '@aws-github-runner/aws-ssm-util';
import moment from 'moment';

import ScaleError from './../scale-runners/ScaleError';
import * as Runners from './runners.d';

const logger = createChildLogger('runners');

interface Ec2Filter {
  Name: string;
  Values: string[];
}

export async function listEC2Runners(
  filters: Runners.ListRunnerFilters | undefined = undefined,
): Promise<Runners.RunnerList[]> {
  const ec2Filters = constructFilters(filters);
  const runners: Runners.RunnerList[] = [];
  for (const filter of ec2Filters) {
    runners.push(...(await getRunners(filter)));
  }
  return runners;
}

function constructFilters(filters?: Runners.ListRunnerFilters): Ec2Filter[][] {
  const ec2Statuses = filters?.statuses ? filters.statuses : ['running', 'pending'];
  const ec2Filters: Ec2Filter[][] = [];
  const ec2FiltersBase = [{ Name: 'instance-state-name', Values: ec2Statuses }];
  if (filters) {
    if (filters.environment !== undefined) {
      ec2FiltersBase.push({ Name: 'tag:ghr:environment', Values: [filters.environment] });
    }
    if (filters.runnerType && filters.runnerOwner) {
      ec2FiltersBase.push({ Name: `tag:ghr:Type`, Values: [filters.runnerType] });
      ec2FiltersBase.push({ Name: `tag:ghr:Owner`, Values: [filters.runnerOwner] });
    }
    if (filters.orphan) {
      ec2FiltersBase.push({ Name: 'tag:ghr:orphan', Values: ['true'] });
    }
  }

  for (const key of ['tag:ghr:Application']) {
    const filter = [...ec2FiltersBase];
    filter.push({ Name: key, Values: ['github-action-runner'] });
    ec2Filters.push(filter);
  }
  return ec2Filters;
}

async function getRunners(ec2Filters: Ec2Filter[]): Promise<Runners.RunnerList[]> {
  const ec2 = getTracedAWSV3Client(new EC2Client({ region: process.env.AWS_REGION }));
  const runners: Runners.RunnerList[] = [];
  let nextToken;
  let hasNext = true;
  while (hasNext) {
    const instances: DescribeInstancesResult = await ec2.send(
      new DescribeInstancesCommand({ Filters: ec2Filters, NextToken: nextToken }),
    );
    hasNext = instances.NextToken ? true : false;
    nextToken = instances.NextToken;
    runners.push(...getRunnerInfo(instances));
  }
  return runners;
}

function getRunnerInfo(runningInstances: DescribeInstancesResult) {
  const runners: Runners.RunnerList[] = [];
  if (runningInstances.Reservations) {
    for (const r of runningInstances.Reservations) {
      if (r.Instances) {
        for (const i of r.Instances) {
          runners.push({
            instanceId: i.InstanceId as string,
            launchTime: i.LaunchTime,
            owner: i.Tags?.find((e) => e.Key === 'ghr:Owner')?.Value as string,
            type: i.Tags?.find((e) => e.Key === 'ghr:Type')?.Value as string,
            repo: i.Tags?.find((e) => e.Key === 'ghr:Repo')?.Value as string,
            org: i.Tags?.find((e) => e.Key === 'ghr:Org')?.Value as string,
            orphan: i.Tags?.find((e) => e.Key === 'ghr:orphan')?.Value === 'true',
            runnerId: i.Tags?.find((e) => e.Key === 'ghr:github_runner_id')?.Value as string,
          });
        }
      }
    }
  }
  return runners;
}

export async function terminateRunner(instanceId: string): Promise<void> {
  logger.debug(`Runner '${instanceId}' will be terminated.`);
  const ec2 = getTracedAWSV3Client(new EC2Client({ region: process.env.AWS_REGION }));
  await ec2.send(new TerminateInstancesCommand({ InstanceIds: [instanceId] }));
  logger.debug(`Runner ${instanceId} has been terminated.`);
}

export async function tag(instanceId: string, tags: Tag[]): Promise<void> {
  logger.debug(`Tagging '${instanceId}'`, { tags });
  const ec2 = getTracedAWSV3Client(new EC2Client({ region: process.env.AWS_REGION }));
  await ec2.send(new CreateTagsCommand({ Resources: [instanceId], Tags: tags }));
}

export async function untag(instanceId: string, tags: Tag[]): Promise<void> {
  logger.debug(`Untagging '${instanceId}'`, { tags });
  const ec2 = getTracedAWSV3Client(new EC2Client({ region: process.env.AWS_REGION }));
  await ec2.send(new DeleteTagsCommand({ Resources: [instanceId], Tags: tags }));
}

function generateFleetOverrides(
  subnetIds: string[],
  instancesTypes: string[],
  amiId?: string,
): FleetLaunchTemplateOverridesRequest[] {
  const result: FleetLaunchTemplateOverridesRequest[] = [];
  subnetIds.forEach((s) => {
    instancesTypes.forEach((i) => {
      const item: FleetLaunchTemplateOverridesRequest = {
        SubnetId: s,
        InstanceType: i as _InstanceType,
        ImageId: amiId,
      };
      result.push(item);
    });
  });
  return result;
}

export async function createRunner(runnerParameters: Runners.RunnerInputParameters): Promise<string[]> {
  logger.debug('Runner configuration.', {
    runner: {
      configuration: {
        ...runnerParameters,
      },
    },
  });

  const ec2Client = getTracedAWSV3Client(new EC2Client({ region: process.env.AWS_REGION }));
  const amiIdOverride = await getAmiIdOverride(runnerParameters);

  const fleet: CreateFleetResult = await createInstances(runnerParameters, amiIdOverride, ec2Client);

  const instances: string[] = await processFleetResult(fleet, runnerParameters);

  logger.info(`Created instance(s): ${instances.join(',')}`);

  return instances;
}

async function processFleetResult(
  fleet: CreateFleetResult,
  runnerParameters: Runners.RunnerInputParameters,
): Promise<string[]> {
  const instances: string[] = fleet.Instances?.flatMap((i) => i.InstanceIds?.flatMap((j) => j) || []) || [];

  if (instances.length === runnerParameters.numberOfRunners) {
    return instances;
  }

  logger.warn(
    `${
      instances.length === 0 ? 'No' : instances.length + ' off ' + runnerParameters.numberOfRunners
    } instances created.`,
    { data: fleet },
  );

  const errors = fleet.Errors?.flatMap((e) => e.ErrorCode || '') || [];

  if (
    errors.some((e) => runnerParameters.onDemandFailoverOnError?.includes(e)) &&
    runnerParameters.ec2instanceCriteria.targetCapacityType === 'spot'
  ) {
    logger.warn(`Create fleet failed, initatiing fall back to on demand instances.`);
    logger.debug('Create fleet failed.', { data: fleet.Errors });
    const numberOfInstances = runnerParameters.numberOfRunners - instances.length;
    const instancesOnDemand = await createRunner({
      ...runnerParameters,
      numberOfRunners: numberOfInstances,
      onDemandFailoverOnError: ['InsufficientInstanceCapacity'],
      ec2instanceCriteria: { ...runnerParameters.ec2instanceCriteria, targetCapacityType: 'on-demand' },
    });
    instances.push(...instancesOnDemand);
    return instances;
  }

  const scaleErrors = runnerParameters.scaleErrors;

  const failedCount = countScaleErrors(errors, scaleErrors);
  if (failedCount > 0) {
    logger.warn('Create fleet failed, ScaleError will be thrown to trigger retry for ephemeral runners.');
    logger.debug('Create fleet failed.', { data: fleet.Errors });
    throw new ScaleError(failedCount);
  }

  logger.warn('Create fleet failed, error not recognized as scaling error.', { data: fleet.Errors });
  throw Error('Create fleet failed, no instance created.');
}

function countScaleErrors(errors: string[], scaleErrors: string[]): number {
  return errors.reduce((acc, e) => (scaleErrors.includes(e) ? acc + 1 : acc), 0);
}

async function getAmiIdOverride(runnerParameters: Runners.RunnerInputParameters): Promise<string | undefined> {
  if (!runnerParameters.amiIdSsmParameterName) {
    return undefined;
  }

  try {
    const amiIdOverride = await getParameter(runnerParameters.amiIdSsmParameterName);
    logger.debug(`AMI override SSM parameter (${runnerParameters.amiIdSsmParameterName}) set to: ${amiIdOverride}`);
    return amiIdOverride;
  } catch (e) {
    logger.debug(
      `Failed to lookup runner AMI ID from SSM parameter: ${runnerParameters.amiIdSsmParameterName}. ` +
        'Please ensure that the given parameter exists on this region and contains a valid runner AMI ID',
      { error: e },
    );
    throw new Error(`Failed to lookup runner AMI ID from SSM parameter: ${runnerParameters.amiIdSsmParameterName},
       ${e}`);
  }
}

/**
 * Find an active Capacity Block reservation matching the requested instance types.
 * Returns the CB ID and its availability zone if found.
 */
async function findActiveCapacityBlock(
  ec2Client: EC2Client,
  instanceTypes: string[],
): Promise<{ capacityReservationId: string; availabilityZone: string } | null> {
  try {
    const response = await ec2Client.send(
      new DescribeCapacityReservationsCommand({
        Filters: [
          { Name: 'state', Values: ['active'] },
          { Name: 'instance-type', Values: instanceTypes },
        ],
      }),
    );

    // Find a capacity block with available capacity
    const activeCB = response.CapacityReservations?.find(
      (cr) => cr.ReservationType === 'capacity-block' && (cr.AvailableInstanceCount ?? 0) > 0,
    );

    if (activeCB && activeCB.CapacityReservationId && activeCB.AvailabilityZone) {
      logger.info(
        `Found active Capacity Block: ${activeCB.CapacityReservationId} in ${activeCB.AvailabilityZone} ` +
          `with ${activeCB.AvailableInstanceCount} available instances`,
      );
      return {
        capacityReservationId: activeCB.CapacityReservationId,
        availabilityZone: activeCB.AvailabilityZone,
      };
    }

    logger.warn('No active Capacity Block found with available capacity', {
      instanceTypes,
      reservationsFound: response.CapacityReservations?.length ?? 0,
    });
    return null;
  } catch (e) {
    logger.error('Failed to describe capacity reservations', { error: e });
    throw e;
  }
}

/**
 * Find a subnet ID from the provided list that is in the specified availability zone.
 */
async function findSubnetInAz(
  ec2Client: EC2Client,
  subnetIds: string[],
  availabilityZone: string,
): Promise<string | null> {
  try {
    const response = await ec2Client.send(
      new DescribeSubnetsCommand({
        SubnetIds: subnetIds,
        Filters: [{ Name: 'availability-zone', Values: [availabilityZone] }],
      }),
    );

    const subnet = response.Subnets?.[0];
    if (subnet?.SubnetId) {
      logger.debug(`Found subnet ${subnet.SubnetId} in availability zone ${availabilityZone}`);
      return subnet.SubnetId;
    }

    logger.warn(`No subnet found in availability zone ${availabilityZone}`, { subnetIds });
    return null;
  } catch (e) {
    logger.error('Failed to describe subnets', { error: e });
    throw e;
  }
}

/**
 * Create instances using RunInstances API for Capacity Block reservations.
 * This is required because CreateFleet does not support auto-discovery for targeted Capacity Blocks.
 */
async function createInstancesFromCapacityBlock(
  runnerParameters: Runners.RunnerInputParameters,
  amiIdOverride: string | undefined,
  ec2Client: EC2Client,
  capacityBlockInfo: { capacityReservationId: string; availabilityZone: string },
  tags: Tag[],
): Promise<CreateFleetResult> {
  // Find a subnet in the same AZ as the capacity block
  const subnetId = await findSubnetInAz(ec2Client, runnerParameters.subnets, capacityBlockInfo.availabilityZone);

  if (!subnetId) {
    throw new Error(
      `No subnet configured in availability zone ${capacityBlockInfo.availabilityZone} ` +
        `where Capacity Block ${capacityBlockInfo.capacityReservationId} is located. ` +
        `Configured subnets: ${runnerParameters.subnets.join(', ')}`,
    );
  }

  logger.info('Creating instance from Capacity Block', {
    capacityReservationId: capacityBlockInfo.capacityReservationId,
    availabilityZone: capacityBlockInfo.availabilityZone,
    subnetId,
    instanceType: runnerParameters.ec2instanceCriteria.instanceTypes[0],
    numberOfRunners: runnerParameters.numberOfRunners,
  });

  try {
    const response = await ec2Client.send(
      new RunInstancesCommand({
        LaunchTemplate: {
          LaunchTemplateName: runnerParameters.launchTemplateName,
          Version: '$Default',
        },
        InstanceType: runnerParameters.ec2instanceCriteria.instanceTypes[0] as _InstanceType,
        SubnetId: subnetId,
        MinCount: runnerParameters.numberOfRunners,
        MaxCount: runnerParameters.numberOfRunners,
        ImageId: amiIdOverride,
        InstanceMarketOptions: {
          MarketType: 'capacity-block',
        },
        CapacityReservationSpecification: {
          CapacityReservationTarget: {
            CapacityReservationId: capacityBlockInfo.capacityReservationId,
          },
        },
        TagSpecifications: [
          {
            ResourceType: 'instance',
            Tags: tags,
          },
          {
            ResourceType: 'volume',
            Tags: tags,
          },
        ],
      }),
    );

    // Wrap the RunInstances response in a CreateFleetResult-compatible structure
    const instanceIds = response.Instances?.map((i) => i.InstanceId).filter((id): id is string => !!id) || [];

    logger.info(`Successfully created ${instanceIds.length} instance(s) from Capacity Block`, {
      instanceIds,
      capacityReservationId: capacityBlockInfo.capacityReservationId,
    });

    const result: CreateFleetResult = {
      Instances: [{ InstanceIds: instanceIds }],
      Errors: [],
    };

    return result;
  } catch (e) {
    logger.warn('RunInstances for Capacity Block failed.', { error: e as Error });
    throw e;
  }
}

async function createInstances(
  runnerParameters: Runners.RunnerInputParameters,
  amiIdOverride: string | undefined,
  ec2Client: EC2Client,
) {
  const tags = [
    { Key: 'ghr:Application', Value: 'github-action-runner' },
    { Key: 'ghr:created_by', Value: runnerParameters.numberOfRunners === 1 ? 'scale-up-lambda' : 'pool-lambda' },
    { Key: 'ghr:Type', Value: runnerParameters.runnerType },
    { Key: 'ghr:Owner', Value: runnerParameters.runnerOwner },
  ];

  if (runnerParameters.tracingEnabled) {
    const traceId = tracer.getRootXrayTraceId();
    tags.push({ Key: 'ghr:trace_id', Value: traceId! });
  }

  // For Capacity Blocks, use RunInstances API instead of CreateFleet
  // CreateFleet does not support auto-discovery for targeted Capacity Blocks (InstanceMatchCriteria: targeted)
  const isCapacityBlock = runnerParameters.ec2instanceCriteria.targetCapacityType === 'capacity-block';

  if (isCapacityBlock) {
    logger.info('Capacity Block target detected, using RunInstances API with dynamic CB discovery');

    // Find an active Capacity Block for the requested instance types
    const capacityBlockInfo = await findActiveCapacityBlock(
      ec2Client,
      runnerParameters.ec2instanceCriteria.instanceTypes,
    );

    if (!capacityBlockInfo) {
      // Throw ScaleError to trigger SQS retry - CB may be provisioning or not yet active
      logger.warn(
        `No active Capacity Block found for instance types: ${runnerParameters.ec2instanceCriteria.instanceTypes.join(', ')}. ` +
          'Will retry via SQS.',
      );
      throw new ScaleError(1);
    }

    return await createInstancesFromCapacityBlock(
      runnerParameters,
      amiIdOverride,
      ec2Client,
      capacityBlockInfo,
      tags,
    );
  }

  // For spot and on-demand, use the standard CreateFleet API
  let fleet: CreateFleetResult;
  try {
    // see for spec https://docs.aws.amazon.com/AWSEC2/latest/APIReference/API_CreateFleet.html
    const createFleetCommand = new CreateFleetCommand({
      LaunchTemplateConfigs: [
        {
          LaunchTemplateSpecification: {
            LaunchTemplateName: runnerParameters.launchTemplateName,
            Version: '$Default',
          },
          Overrides: generateFleetOverrides(
            runnerParameters.subnets,
            runnerParameters.ec2instanceCriteria.instanceTypes,
            amiIdOverride,
          ),
        },
      ],
      SpotOptions: {
        MaxTotalPrice: runnerParameters.ec2instanceCriteria.maxSpotPrice,
        AllocationStrategy: runnerParameters.ec2instanceCriteria.instanceAllocationStrategy,
      },
      TargetCapacitySpecification: {
        TotalTargetCapacity: runnerParameters.numberOfRunners,
        DefaultTargetCapacityType: runnerParameters.ec2instanceCriteria.targetCapacityType,
      },
      TagSpecifications: [
        {
          ResourceType: 'instance',
          Tags: tags,
        },
        {
          ResourceType: 'volume',
          Tags: tags,
        },
      ],
      Type: 'instant',
    });
    fleet = await ec2Client.send(createFleetCommand);
  } catch (e) {
    logger.warn('Create fleet request failed.', { error: e as Error });
    throw e;
  }
  return fleet;
}

// If launchTime is undefined, this will return false
export function bootTimeExceeded(ec2Runner: { launchTime?: Date }): boolean {
  const runnerBootTimeInMinutes = process.env.RUNNER_BOOT_TIME_IN_MINUTES;
  const launchTimePlusBootTime = moment(ec2Runner.launchTime).utc().add(runnerBootTimeInMinutes, 'minutes');
  return launchTimePlusBootTime < moment(new Date()).utc();
}
