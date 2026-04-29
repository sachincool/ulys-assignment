import * as gcp from "@pulumi/gcp";
import * as pulumi from "@pulumi/pulumi";

export interface MemorystoreArgs {
  name: string;
  region: pulumi.Input<string>;
  vpcId: pulumi.Input<string>;
  tier: "BASIC" | "STANDARD_HA";  // STANDARD_HA = ~$70/mo + RDB persistence
  memoryGb: number;
  authEnabled?: boolean;           // requires AUTH header from clients
  transitEncryption?: "SERVER_AUTHENTICATION" | "DISABLED";
}

/**
 * Memorystore Redis on private services access (peers off the VPC's
 * service-networking connection).
 *
 * For production, prefer STANDARD_HA: it survives zonal failure with a
 * 30-second failover. For dev/staging, BASIC is fine.
 *
 * AUTH + transit encryption are off in dev (cheaper, simpler) and on in
 * staging/prod. The app reads the AUTH string from the GCS-Pulumi-output
 * Secret Manager binding the runtime stack creates.
 */
export class Memorystore extends pulumi.ComponentResource {
  public readonly instance: gcp.redis.Instance;

  constructor(name: string, args: MemorystoreArgs, opts?: pulumi.ComponentResourceOptions) {
    super("ulys:cache:Memorystore", name, {}, opts);

    this.instance = new gcp.redis.Instance(name, {
      region: args.region,
      tier: args.tier,
      memorySizeGb: args.memoryGb,
      authorizedNetwork: args.vpcId,
      redisVersion: "REDIS_7_0",
      connectMode: "PRIVATE_SERVICE_ACCESS",
      authEnabled: args.authEnabled ?? false,
      transitEncryptionMode: args.transitEncryption ?? "DISABLED",
      persistenceConfig: args.tier === "STANDARD_HA"
        ? { persistenceMode: "RDB", rdbSnapshotPeriod: "TWELVE_HOURS" }
        : undefined,
      maintenancePolicy: {
        weeklyMaintenanceWindows: [{
          day: "SUNDAY",
          startTime: { hours: 4, minutes: 0, seconds: 0, nanos: 0 },
        }],
      },
    }, { parent: this });

    this.registerOutputs({
      host: this.instance.host,
      port: this.instance.port,
    });
  }
}
