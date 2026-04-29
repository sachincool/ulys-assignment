import * as gcp from "@pulumi/gcp";
import * as pulumi from "@pulumi/pulumi";

export interface NetworkArgs {
  name: string;
  region: pulumi.Input<string>;
  podsCidr?: string;     // GKE pods range
  servicesCidr?: string; // GKE services range
  masterCidr?: string;   // GKE control plane peering range
  subnetCidr?: string;
}

/**
 * VPC + subnet + private services access for Cloud SQL/Memorystore +
 * Cloud NAT for egress + the secondary ranges GKE Autopilot needs.
 *
 * No serverless VPC connector here — Autopilot doesn't need one. Cloud Run
 * is intentionally out of scope for this stack.
 */
export class Network extends pulumi.ComponentResource {
  public readonly vpc: gcp.compute.Network;
  public readonly subnet: gcp.compute.Subnetwork;
  public readonly psaConnection: gcp.servicenetworking.Connection;

  constructor(name: string, args: NetworkArgs, opts?: pulumi.ComponentResourceOptions) {
    super("ulys:net:Network", name, {}, opts);

    const subnetCidr   = args.subnetCidr   ?? "10.10.0.0/22";
    const podsCidr     = args.podsCidr     ?? "10.20.0.0/16";
    const servicesCidr = args.servicesCidr ?? "10.30.0.0/20";

    this.vpc = new gcp.compute.Network(name, {
      autoCreateSubnetworks: false,
      routingMode: "REGIONAL",
    }, { parent: this });

    this.subnet = new gcp.compute.Subnetwork(`${name}-subnet`, {
      ipCidrRange: subnetCidr,
      region: args.region,
      network: this.vpc.id,
      privateIpGoogleAccess: true,
      secondaryIpRanges: [
        { rangeName: "pods",     ipCidrRange: podsCidr     },
        { rangeName: "services", ipCidrRange: servicesCidr },
      ],
    }, { parent: this });

    // Private services access — Cloud SQL & Memorystore use this for
    // private IP. /16 reservation is the convention; the actual ranges
    // Google carves out are smaller.
    const psaRange = new gcp.compute.GlobalAddress(`${name}-psa`, {
      purpose: "VPC_PEERING",
      addressType: "INTERNAL",
      prefixLength: 16,
      network: this.vpc.id,
    }, { parent: this });

    this.psaConnection = new gcp.servicenetworking.Connection(`${name}-psa`, {
      network: this.vpc.id,
      service: "servicenetworking.googleapis.com",
      reservedPeeringRanges: [psaRange.name],
    }, { parent: this });

    // Cloud NAT — outbound internet for the cluster (e.g., pulling images
    // from public registries the proxy hasn't cached yet, calling third-
    // party APIs). Single regional gateway, automatic IP allocation.
    const router = new gcp.compute.Router(`${name}-router`, {
      region: args.region,
      network: this.vpc.id,
    }, { parent: this });

    new gcp.compute.RouterNat(`${name}-nat`, {
      router: router.name,
      region: args.region,
      natIpAllocateOption: "AUTO_ONLY",
      sourceSubnetworkIpRangesToNat: "ALL_SUBNETWORKS_ALL_IP_RANGES",
      logConfig: { enable: true, filter: "ERRORS_ONLY" },
    }, { parent: this });

    this.registerOutputs({
      vpcId: this.vpc.id,
      subnetId: this.subnet.id,
    });
  }
}
