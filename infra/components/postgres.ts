import * as gcp from "@pulumi/gcp";
import * as pulumi from "@pulumi/pulumi";
import * as random from "@pulumi/random";

export interface PostgresArgs {
  name: string;
  region: pulumi.Input<string>;
  vpcId: pulumi.Input<string>;
  /**
   * Tier:
   *   dev      → "db-f1-micro"  (shared core, ~$9/mo, no HA)
   *   staging  → "db-custom-1-3840"  (1 vCPU, 3.75 GB)
   *   prod     → "db-custom-2-7680"  (2 vCPU, 7.5 GB) + HA
   */
  tier: pulumi.Input<string>;
  ha: boolean;          // REGIONAL availability + automatic failover
  pitr: boolean;        // point-in-time recovery (binlog/wal retention)
  diskSizeGb?: number;  // 10 dev / 50 prod
  databases?: string[]; // names to create within the instance
  /**
   * The KMS key for customer-managed encryption at rest. Strongly recommended
   * for prod; required if VPC SC is on. Pass undefined for dev.
   */
  kmsKey?: pulumi.Input<string>;
}

/**
 * Cloud SQL Postgres with private IP, no public surface.
 *
 * Connection from the cluster: Cloud SQL Auth Proxy as a CSI volume mount
 * (one connection per node, not per pod). The proxy authenticates via the
 * pod's KSA → GSA mapping; no DB password lives on the network. The
 * generated password below exists only as a fallback for direct admin
 * access during break-glass; the app uses IAM auth.
 *
 * Migrations live in apps/api/migrations and are applied by an Atlas
 * Kubernetes Job in a pre-sync Argo CD hook.
 */
export class Postgres extends pulumi.ComponentResource {
  public readonly instance: gcp.sql.DatabaseInstance;
  public readonly password: pulumi.Output<string>;
  public readonly user: gcp.sql.User;

  constructor(name: string, args: PostgresArgs, opts?: pulumi.ComponentResourceOptions) {
    super("ulys:db:Postgres", name, {}, opts);

    this.instance = new gcp.sql.DatabaseInstance(name, {
      region: args.region,
      databaseVersion: "POSTGRES_15",
      deletionProtection: args.ha, // prod-only
      settings: {
        tier: args.tier,
        availabilityType: args.ha ? "REGIONAL" : "ZONAL",
        diskSize: args.diskSizeGb ?? (args.ha ? 50 : 10),
        diskAutoresize: true,
        ipConfiguration: {
          ipv4Enabled: false,
          privateNetwork: args.vpcId,
        },
        backupConfiguration: {
          enabled: args.pitr || args.ha,
          pointInTimeRecoveryEnabled: args.pitr,
          startTime: "03:00",
          backupRetentionSettings: { retainedBackups: args.ha ? 30 : 7 },
        },
        databaseFlags: [
          { name: "cloudsql.iam_authentication", value: "on" },
          { name: "log_min_duration_statement", value: "500" },
        ],
        insightsConfig: {
          queryInsightsEnabled: true,
          recordApplicationTags: true,
          recordClientAddress: false, // PII
        },
        maintenanceWindow: { day: 7, hour: 4, updateTrack: "stable" },
      },
      encryptionKeyName: args.kmsKey,
    }, { parent: this, protect: args.ha });

    for (const db of args.databases ?? ["app"]) {
      new gcp.sql.Database(`${name}-${db}`, {
        instance: this.instance.name,
        name: db,
      }, { parent: this });
    }

    // Break-glass password. App connects via Cloud SQL Auth Proxy + IAM,
    // not this password.
    const pw = new random.RandomPassword(`${name}-pw`, {
      length: 32, special: false,
    }, { parent: this });
    this.password = pw.result;

    this.user = new gcp.sql.User(`${name}-user`, {
      instance: this.instance.name,
      name: "app",
      password: this.password,
    }, { parent: this });

    this.registerOutputs({
      privateIp: this.instance.privateIpAddress,
      connectionName: this.instance.connectionName,
    });
  }
}
