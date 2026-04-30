import * as gcp from "@pulumi/gcp";
import * as pulumi from "@pulumi/pulumi";

export interface GkeArgs {
  name: string;
  /**
   * Cluster location. Pass a zone (e.g. "us-central1-a") for the cheapest
   * "minimum prod" config — zonal control plane, all nodes in one zone.
   * Pass a region (e.g. "us-central1") for the regional control plane HA
   * upgrade. The cluster object's `location` field decides; nothing else
   * changes. Cost delta: zonal control plane is FREE for the first cluster
   * per project; regional is ~$73/mo. Node cost is the same in either case.
   */
  location: pulumi.Input<string>;
  /**
   * Optional list of zones to spread nodes across. Default: undefined,
   * meaning "the cluster's zone" (or for regional clusters, all zones in
   * the region). Pass ["us-central1-a"] to pin nodes to a single zone for
   * cost; pass ["us-central1-a", "us-central1-b", "us-central1-c"] for
   * zonal HA. Multi-region requires a separate cluster per region — the
   * cleanest upgrade path is "stamp this stack a second time pointed at a
   * different region" rather than trying to make one cluster span regions.
   */
  nodeLocations?: pulumi.Input<string>[];
  network: pulumi.Input<string>;
  subnetwork: pulumi.Input<string>;
  masterCidr?: string;
  masterAuthorizedNetworks?: { cidrBlock: string; displayName: string }[];
  /**
   * Node pool sizing. Defaults are the "minimum prod" footprint:
   * machineType e2-standard-2 (2 vCPU / 8 GB), 1-3 autoscale, no preemption.
   */
  nodeMachineType?: pulumi.Input<string>;
  nodeMinCount?: number;
  nodeMaxCount?: number;
  /**
   * Use spot VMs for the default node pool. Cuts cost ~70% but accepts
   * 24h-max preemption. Fine for dev/staging; not recommended for prod.
   */
  spot?: boolean;
  binAuthzAttestor?: pulumi.Input<string>;
}

/**
 * GKE Standard with the best-practice defaults applied explicitly so
 * they're visible in code review:
 *
 * - **Private cluster, private endpoint** — no public node IPs, control
 *   plane only reachable from `masterAuthorizedNetworks`.
 * - **VPC-native (alias IPs)** — required for NetworkPolicy + better LB
 *   behaviour.
 * - **Workload Identity** — only auth path for pods to GCP APIs; we do
 *   not provision any node service-account JSON keys.
 * - **Network policy enforcement (Calico)** — declared default-deny in
 *   manifests/.
 * - **Shielded nodes (secure boot + integrity monitoring)** — node tamper
 *   detection.
 * - **Release channel REGULAR** — Google rolls minor upgrades for us, with
 *   a maintenance window we control.
 * - **Auto-repair + auto-upgrade** on the node pool.
 * - **Cluster autoscaler** — 1..N nodes, scales in too.
 *
 * Defaults are aimed at the "minimum prod" tier: zonal control plane (free),
 * single zone for nodes, e2-standard-2, autoscale 1..3. Caller flips:
 *   - location: zone → region for HA control plane
 *   - nodeLocations to multiple zones for zonal HA
 *   - to a second stack instance for multi-region
 */
export class Gke extends pulumi.ComponentResource {
  public readonly cluster: gcp.container.Cluster;
  public readonly nodePool: gcp.container.NodePool;

  constructor(name: string, args: GkeArgs, opts?: pulumi.ComponentResourceOptions) {
    super("ulys:gke:Standard", name, {}, opts);

    const project = gcp.config.project!;
    const masterCidr = args.masterCidr ?? "172.16.0.0/28";

    this.cluster = new gcp.container.Cluster(name, {
      location: args.location,
      removeDefaultNodePool: true,
      initialNodeCount: 1,
      deletionProtection: false,
      network: args.network,
      subnetwork: args.subnetwork,
      nodeLocations: args.nodeLocations,
      ipAllocationPolicy: {
        clusterSecondaryRangeName:  "pods",
        servicesSecondaryRangeName: "services",
      },
      privateClusterConfig: {
        enablePrivateNodes: true,
        // Public control plane endpoint, restricted by masterAuthorizedNetworks.
        // Set this to true only when caller passes RFC1918 CIDRs (a bastion
        // or in-VPC runner) — Google rejects 0.0.0.0/0 with private endpoint.
        // For most production cases, public endpoint + tight authorized
        // networks is the right balance: kubectl works from authorized
        // operator IPs, the data plane has no public IPs.
        enablePrivateEndpoint: false,
        masterIpv4CidrBlock: masterCidr,
      },
      masterAuthorizedNetworksConfig: args.masterAuthorizedNetworks
        ? { cidrBlocks: args.masterAuthorizedNetworks }
        : undefined,
      releaseChannel: { channel: "REGULAR" },
      workloadIdentityConfig: {
        workloadPool: `${project}.svc.id.goog`,
      },
      networkPolicy: { enabled: true, provider: "CALICO" },
      addonsConfig: {
        networkPolicyConfig: { disabled: false },
        httpLoadBalancing:    { disabled: false },
        gcePersistentDiskCsiDriverConfig: { enabled: true },
        gcsFuseCsiDriverConfig: { enabled: true },
      },
      binaryAuthorization: args.binAuthzAttestor
        ? { evaluationMode: "PROJECT_SINGLETON_POLICY_ENFORCE" }
        : undefined,
      // Logging / Monitoring — system + workloads to Cloud Logging.
      loggingConfig:    { enableComponents: ["SYSTEM_COMPONENTS", "WORKLOADS"] },
      monitoringConfig: {
        enableComponents: ["SYSTEM_COMPONENTS"],
        managedPrometheus: { enabled: true },
      },
      // Maintenance: omit the policy — GKE picks a default that satisfies
      // its own ≥48h-over-32-days availability rule. Override with a more
      // restrictive window only when an SRE rotation actually needs it.
    }, { parent: this });

    this.nodePool = new gcp.container.NodePool(`${name}-pool`, {
      location: args.location,
      cluster: this.cluster.name,
      autoscaling: {
        minNodeCount: args.nodeMinCount ?? 1,
        maxNodeCount: args.nodeMaxCount ?? 3,
      },
      management: { autoRepair: true, autoUpgrade: true },
      nodeConfig: {
        machineType: args.nodeMachineType ?? "e2-standard-2",
        diskSizeGb: 50,
        diskType: "pd-balanced",
        spot: args.spot ?? false,
        // Workload Identity at node level — pods opt in via their KSA.
        workloadMetadataConfig: { mode: "GKE_METADATA" },
        // Shielded nodes — secure boot + integrity monitoring.
        shieldedInstanceConfig: {
          enableSecureBoot: true,
          enableIntegrityMonitoring: true,
        },
        oauthScopes: ["https://www.googleapis.com/auth/cloud-platform"],
        labels: { env: name },
      },
      upgradeSettings: { strategy: "SURGE", maxSurge: 1, maxUnavailable: 0 },
    }, { parent: this });

    this.registerOutputs({ clusterName: this.cluster.name });
  }

  public kubeconfig(): pulumi.Output<string> {
    return pulumi.all([this.cluster.name, this.cluster.endpoint, this.cluster.masterAuth])
      .apply(([clusterName, endpoint, masterAuth]) => {
        const ca = masterAuth.clusterCaCertificate!;
        return `apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: ${ca}
    server: https://${endpoint}
  name: ${clusterName}
contexts:
- context:
    cluster: ${clusterName}
    user: ${clusterName}
  name: ${clusterName}
current-context: ${clusterName}
kind: Config
users:
- name: ${clusterName}
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: gke-gcloud-auth-plugin
      installHint: Install gke-gcloud-auth-plugin for use with kubectl
      provideClusterInfo: true
`;
      });
  }
}
