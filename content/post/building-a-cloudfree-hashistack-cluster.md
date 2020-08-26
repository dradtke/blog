+++
date = "2020-06-25"
title = "Building a Cloud™-Free Hashistack Cluster 🌥"
draft = true
+++

## Table of Contents

1. [Preface](#preface)
2. [Getting Started](#getting-started)
3. [Safety First: TLS](#safety-first-tls)
4. [Behind the Firewall](#behind-the-firewall)
5. [Provisioning With Terraform](#provisioning-with-terraform)
6. [Running a Website](#running-a-website)

## Preface

"Hashistack" refers to a network cluster based on [HashiCorp](https://www.hashicorp.com/) tools, and
after spending some time on it off-and-on, the architecture of my own cluster (on which this blog is
running, among other personal projects) has finally stabilized. In this post I will walk you through
its high-level structure, some of the benefits provided, and hopefully show you how you can build a
similar cluster for your personal or professional projects.

For the impatient, everything I am talking about here is available publicly in my [infrastructure
repo](https://git.sr.ht/~damien/infrastructure/). For the more patient, read on.

## The Cloud™

The term "cloud" can be pretty ambiguous, but usually refers to some version of a platform providing
managed services beyond a simple Virtual Private Server, or VPS. In this post, I want to draw a
distinction between VPS providers and Cloud™ providers. While there are many different VPS
providers, here I use the term Cloud™ to refer to the big 3: AWS, Azure, and GCP.

There is nothing inherently wrong with building applications on the Cloud™, but almost by
definition, there is less to discuss here, especially with the recent launch of [HashiCorp Cloud
Platform](https://www.hashicorp.com/cloud-platform/). These services let you get up and running
quickly, but also often come with a hefty price tag. Sticking with VPS providers can save you money
and, in my opinion, is more fun.

My cluster is built on [Linode](https://www.linode.com/) because they offer openSUSE VPS images and
DNS management. However, this guide should still be relevant no matter what distribution you're
using, though with some extra steps if you do not have
[`systemd`](https://www.freedesktop.org/wiki/Software/systemd/) or
[`firewalld`](https://firewalld.org/) available.


## Getting Started

### Create a Support Server

A primary fixture in my setup is the use of a "support" server, which is a single VPS instance that
acts as the entrypoint for the rest of the cluster. Most of the infrastructure is provisioned with
Terraform and is designed to be easily replaceable; the support server is the lone instance which is
cared for as a [pet](http://cloudscaling.com/blog/cloud-computing/the-history-of-pets-vs-cattle/)
rather than cattle. This is very similar in concept to a bastion server, but with less of a focus on
security, and more on cost savings and functionality.

The support server's functions include:

1. Cluster members are provisioned with a random root password which is never exposed; **access is
   only granted via SSH public keys**, and never to `root` (after provisioning has finished).
   Restricting authorized keys to only what is available on the support server is an easy way to
   tighten your security. (My setup is actually slightly different in that servers only allow access
   with the public keys defined in Linode and I always forward my SSH agent to the support server,
   but I still do all cluster operations on the support server.)
2. The support server acts as the **guardian of the Certificate Authorities**, and new certificates
   are only issued by making a request to the support server.
3. The support server **maintains Terraform state**. Setting up a backend is an option here as well,
   but for relatively simple uses like mine, it's easier to stick with the "local" backend on the
   support server.
4. **Cheap artifact hosting**. As long as you have a server running with a known address, you can have
   your support server host all your artifacts and serve them with [minio](https://min.io/) or even
   a plain HTTP server.

### A Note on IPv6

Where possible, everything is configured to communicate over IPv6. Despite its slow adoption, IPv6
is a good choice here because it is more efficient, opens up another possible route for cost savings
due to the scarcity of IPv4 addresses, and VPS providers are more likely to support it than Internet
Service Providers anyway.

## Safety First: TLS

In order to safely restrict access to cluster resources, the first step you'll want to take with
your support server is to generate Certificate Authorities that can be used to configure TLS for
each of the services. My setup largely follows the approach outlined in HashiCorp's guide to
[enabling TLS for Nomad](https://learn.hashicorp.com/nomad/transport-security/enable-tls), which
will go more in-depth in how to use `cfssl` to get set up.

It might be overkill, but I use a different CA for each service, and they are stored on the support
server under `/etc/ssl`:


{{<highlight text>}}
/etc/ssl
├── consul
│   ├── ca-key.pem
│   └── ca.pem
├── nomad
│   ├── ca-key.pem
│   └── ca.pem
└── vault
    ├── ca-key.pem
    └── ca.pem
{{</highlight>}}

Another important security note is that the key permissions should be as restrictive as possible:

{{<highlight text>}}
-r-------- 1 root root  227 Jul 23  2019 /etc/ssl/consul/ca-key.pem
-r--r--r-- 1 root root 1249 Jul 23  2019 /etc/ssl/consul/ca.pem
{{</highlight>}}

### CFSSL Configuration

CFSSL is a general-purpose CLI tool for managing TLS files, but it also has the
ability to run a server process for handling new certificate requests. That
requires defining a configuration file at `/etc/ssl/cfssl.json` on the support server:

{{<highlight json>}}
{
  "signing": {
    "default": {
      "expiry": "87600h",
      "usages": [
        "signing",
        "key encipherment",
        "server auth",
        "client auth"
      ],
      "auth_key": "primary"
    }
  },
  "auth_keys": {
    "primary": {
      "type": "standard",
      "key": "..."
    }
  }
}
{{</highlight>}}

The `primary` auth key here must be a 16-bit hex value, and is used to prevent unauthorized parties
from requesting certificates. All new certificate requests effectively use that key as a password,
so treat it just like you would treat your private keys by *never* checking it into source control.
For more details on CFSSL configuration, see CloudFlare's post on [building your own public key
infrastructure](https://blog.cloudflare.com/how-to-build-your-own-public-key-infrastructure/).

There is one other tool that CFSSL provides but isn't mentioned in the article called `multirootca`,
which is effectively just a multiplexer for CFSSL. By default, the CFSSL server will only issue
certificates for a single Certificate Authority; `multirootca` lets you run the server in a way that
supports multiple authorities. It requires its own configuration file, but a very simple one:

{{<highlight conf>}}
[ consul ]
private = file:///etc/ssl/consul/ca-key.pem
certificate = /etc/ssl/consul/ca.pem
config = /etc/ssl/cfssl.json

[ vault ]
private = file:///etc/ssl/vault/ca-key.pem
certificate = /etc/ssl/vault/ca.pem
config = /etc/ssl/cfssl.json

[ nomad ]
private = file:///etc/ssl/nomad/ca-key.pem
certificate = /etc/ssl/nomad/ca.pem
config = /etc/ssl/cfssl.json
{{</highlight>}}

The `multirootca`
[service](https://git.sr.ht/~damien/infrastructure/tree/master/services/support/multirootca.service)
is then run under systemd so that it can keep running in the background, serving incoming
certificate requests.

Issuing new certificates is done from every cluster member via [this
script](https://git.sr.ht/~damien/infrastructure/tree/master/scripts/issue-cert.sh), which uses the
CFSSL CLI to make a `gencert` request to the running `multirootca` service on the support server.
Like the support server, certs and keys on cluster members all live under `/etc/ssl`, grouped by
application name, including the public key for the certificate authority.

One thing to note is how Consul, Nomad, and Vault interact with each other, since that affects which
certificates you need to issue. Vault depends on Consul, and Nomad depends on both Consul and Vault,
so an instance running a Nomad agent will have a lot of certificates in `/etc/ssl/nomad`:

{{<highlight text>}}
-rw-r--r-- 1 nomad nomad 692 Jun 14 21:59 ca.pem
-r--r----- 1 nomad nomad 228 Jun 14 22:00 cli-key.pem
-rw-r--r-- 1 nomad nomad 714 Jun 14 22:00 cli.pem
-r-------- 1 nomad nomad 228 Jun 14 22:00 consul-key.pem
-rw-r--r-- 1 nomad nomad 970 Jun 14 22:00 consul.pem
-r-------- 1 nomad nomad 228 Jun 15 19:07 nomad-key.pem
-rw-r--r-- 1 nomad nomad 803 Jun 15 19:07 nomad.pem
-r-------- 1 nomad nomad 228 Jun 14 22:00 vault-key.pem
-rw-r--r-- 1 nomad nomad 714 Jun 14 22:00 vault.pem
{{</highlight>}}

### A Note on Hostnames

While working on this project, the most common TLS-related errors I encountered were "unknown
certificate authority" and "bad hostname." The former is usually pretty easy to fix; just ensure
`ca.pem` is available on every node and that it's being used as the relevant CA in the configs; but
the latter requires a little more thought.

Every node needs to consider how it is going to be queried. By default, `issue-cert.sh` considers
only `localhost` to be a valid hostname, which means that only API requests to `localhost` will be
accepted, which in turn means that all requests from another location (like the support server) will
be rejected. If you want to query your node using another name, it needs to be included as a valid
hostname when the certificate is issued.

For all nodes, the public IP address is a common alternative hostname to specify. This will let you
query the node from anywhere as long as your CLI is configured with its own valid certificate (a
separate [script](https://git.sr.ht/~damien/infrastructure/tree/master/tools/issue-cert) makes this
pretty easy; it's very similar to the one used during node provisioning, but it operates directly on
the CA private key instead of using the remote).

In addition, there are a couple special cases to consider:

1. Consul services should add `<name>.service.consul` as a valid hostname. Both Nomad and Vault
   servers register their own services, so they should add `nomad.service.consul` and
   `vault.service.consul` respectively.
2. All Nomad agents, both servers and clients, should add their [special
   hostname](https://learn.hashicorp.com/nomad/transport-security/enable-tls#node-certificates),
   which is constructed from the agent's role and region. All Nomad agents in my cluster stick with
   the default region `global`, so Nomad servers use `server.global.nomad` and clients use
   `client.global.nomad`.

## Behind the Firewall

With any cluster, a properly-configured firewall is a _must_. I use
[`firewalld`](https://firewalld.org/), which is the new default for openSUSE, and it's not too
difficult to configure.

`firewalld` defines two important concepts for classifying incoming connections: **services** and
**zones**. Services simply define a list of protocol/port pairs that are identified by a name; for
example, the `ssh` service would be defined as `tcp/22`, because it requires TCP connections on port
22. Zones, roughly speaking, are used to classify where a connection is coming from, and what should
be done with it, such as "for any connection to one of these services, from one of these IP
addresses, accept it." Connections that aren't explicitly given access will be dropped by default.

The full list of features `firewalld` provides for zones is outside the scope of this post, and if
you plan to use `firewalld`, it's probably good to [read
more](https://www.linuxjournal.com/content/understanding-firewalld-multi-zone-configurations).
However, it is still useful even with a very simple configuration.

One benefit of having TLS configured for Consul, Nomad, and Vault is that it is perfectly safe to
open their ports to any incoming connection regardless of source IP, since connections will be
rejected if they do not have a valid client certificate anyway.  There is a lot of room for
flexibility here though, and further restrictions may be wanted if you expect [sensitive
information](https://www.youtube.com/watch?v=xpfCr4By71U) to go through your cluster.

### Creating a Cluster-Only Zone

The natural fit for a more secure zone is one that only processes requests coming from other nodes
inside your cluster. While my setup leaves many ports open to the world, there is one exception:
Nomad client dynamic ports. While connections to Nomad directly require a client certificate, I
wanted my applications running on Nomad to be able to communicate with each other (more on that
below), and that requires opening up the dynamic port range to the other Nomad clients.

To do this, I created a new service called
[`nomad-dynamic-ports`](https://git.sr.ht/~damien/infrastructure/tree/master/firewall/services/nomad-dynamic-ports.xml)
that grants access to the [port
range](https://www.nomadproject.io/docs/job-specification/network#dynamic-ports) used by Nomad. All
applications running on Nomad that request a port will be assigned a random one from this range, so
we want to open up the whole range, but _only to other Nomad clients_.

Each Nomad client is provisioned with a zone called `nomad-clients`, which allows access to the
`nomad-dynamic-ports` service, but with no other information, so by default no connections will land
in this zone. In order for it to work, we need to add the IP address of every other Nomad client as
a source to this zone, and to do this for all the clients.

To do this, I wrote a
[script](https://git.sr.ht/~damien/infrastructure/tree/master/tools/update-nomad-client-firewall)
that uses Terraform output to get a list of all the Nomad client IP addresses, then SSH on to each
one and make the necessary updates. This script can be run automatically by Terraform with a
[`null_resource`](https://registry.terraform.io/providers/hashicorp/null/latest/docs/resources/resource),
which will help keep things in sync.

## Provisioning With Terraform

Terraform was not actually my go-to solution for provisioning. Initially my plan was to stay simple
and stick with scripts like `deploy-new-server.sh` using Linode's API, but I ended up moving over to
Terraform for one big reason: state management. Terraform's big win is keeping track of what you've
already deployed, which makes cluster management much easier. In particular, you can provision your
client nodes with [existing
knowledge](https://git.sr.ht/~damien/infrastructure/tree/c97e0e2b/terraform/nomad-client/main.tf#L70-74)
of your Consul servers, and write
[scripts](https://git.sr.ht/~damien/infrastructure/tree/master/tools/update-nomad-client-firewall)
that can use that knowledge after-the-fact to make additional changes. All of these operations are
much easier with a state management tool than they would be if you had to query your VPS' API every
time you wanted to know a node's IP address.

### Overall Structure

[How to organize Terraform code](https://duckduckgo.com/?q=how+to+organize+terraform+files) is a
question of constant debate, and the right answer is that there is no right answer. A lot of it
depends on how you organize your teams, so bear in mind that my cluster is maintained by a team of
one.

My module structure has one top-level module, with one module for each "role" that my nodes will
play:

{{<highlight text>}}
├── main.tf
├── outputs.tf
├── secrets.tfvars
├── consul-server
│   ├── main.tf
│   ├── outputs.tf
│   └── variables.tf
├── nomad-client
│   ├── main.tf
│   ├── outputs.tf
│   └── variables.tf
├── nomad-server
│   ├── main.tf
│   ├── outputs.tf
│   └── variables.tf
└── vault-server
    ├── main.tf
    ├── outputs.tf
    └── variables.tf
{{</highlight>}}

Each of these modules has a number of variables in common, including how many instances to create,
which image to use when creating the node, and a couple of other values. Most of their inputs are
the same, but this provides a lot of flexibility, and common values are usually sourced from a block
of shared `locals`.

This setup has several advantages, primarily flexibility and a [top-level
`main.tf`](https://git.sr.ht/~damien/infrastructure/tree/master/terraform/main.tf) that is able to
describe the makeup of your cluster very cleanly, but the downside is that it is fairly verbose
within the module definitions. Terraform doesn't appear to provide any utilities for defining a
set of provisioners that can be shared across resources, which would help quite a bit.

### Division of Provision

The provisioning of a new node is split between a custom
[stackscript](https://git.sr.ht/~damien/infrastructure/tree/master/stackscripts/cluster-member.sh)
and Terraform [provisioners](https://www.terraform.io/docs/provisioners/index.html). The stackscript
installs packages and does other configuration that is common across nodes, while the Terraform
provisioners are used to copy [configuration
files](https://git.sr.ht/~damien/infrastructure/tree/master/config) up from the infra repo directly
and to write configuration files that are dependent on cluster knowledge, such as the addresses of
the Consul servers.

An alternative, and arguably better, setup would be to use [Packer](https://www.packer.io/) to
define the node images, leaving nothing for Terraform to do except deploy instances and do the
little configuration that requires cluster knowledge. Unfortunately, this is an area where Linode
may not be a great choice; while Packer does support a Linode image builder, custom Linode images
don't appear to be compatible with their network helper tool, which causes basic networking to be
[broken by default](https://git.sr.ht/~damien/infrastructure/tree/c97e0e2b/packer/README.md).

### Naming Things

Initially, I took a very simple approach to naming nodes by their role, region, and an index, such
as `nomad-server-ca-central-1`. However, this approach lacks flexibility when it comes to upgrading
your cluster. If you want to replace a node, it is safest to create a new one and make sure it's up
and running before destroying the old one, but now your carefully numbered servers are no longer in
order.

Fortunately, Terraform provides a [random
provider](https://registry.terraform.io/providers/hashicorp/random/latest/docs) that can be used to
name your nodes instead by generating random identifiers. I use something similar to this:

{{<highlight hcl>}}
resource "random_id" "servers" {
    count = var.servers
    keepers = {
        datacenter     = var.datacenter
        image          = var.image
        instance_type  = var.instance_type
        consul_version = var.consul_version
        nomad_version  = var.nomad_version
    }
    byte_length = 4
}

resource "linode_instance" "servers" {
    count = var.servers
    label = "nomad-server-${var.datacenter}-${replace(random_id.servers[count.index].b64_url, "-", "_")}"
}
{{</highlight>}}

This gives each Nomad server a name like `nomad-server-ca-central-XXXXXX`, where `XXXXXX` is a
base64-encoded random string. The URL-safe base64-encoding is used, but Linode doesn't allow two
consecutive dashes in instance labels, so the `replace()` function is used to replace dashes with
underscores in order to prevent a provision failure caused by a dash as the first letter in a server
id. (It's happened to me once already, not a fun reason for the apply to fail)

## Running a Website

At this point, we've covered pretty much everything you need to be able to spin up a functional
cluster.  However, as I mentioned before, this blog is currently running on my own cluster, and
there are a number of extra steps that need to be taken in order to support running a website. In
this section, I will cover the points that are specific to running a website on this setup. While
web servers are similar to any other job type in many respects, there are a few additional concerns
that bear special mention.

### Load Balancing

Running a website on Nomad makes it easy to scale up, but running more than one instance of a web
server requires some form of load balancer. The big name in load balancers is
[HAProxy](http://www.haproxy.org/), but a few newer ones can take advantage of Consul's
service-registration features in order to "just work" with no or minimal configuration. For this
website I chose [Fabio](https://fabiolb.net/), but [Traefik](https://docs.traefik.io/) is another
good option.

Regardless of which you choose, you will then have to decide how to run it. Naturally, I decided to
run Fabio as a [Nomad
job](https://git.sr.ht/~damien/infrastructure/tree/master/jobs/fabio.nomad.erb) too, but due to the
nature of load balancing, it has tighter restrictions for how it can run. Most jobs, including the
web server itself, don't actually care which nodes they run on, but load balancers need their host
to be registered with DNS. This means that we need the nodes themselves to know whether they are
intended to run a load balancer or not.

Nomad provides a number of filtering options for jobs including custom metadata, but I decided to go
with the [`node_class`](https://www.nomadproject.io/docs/configuration/client#node_class) attribute.
This is a custom value that you can asign each Nomad client explicitly for filtering purposes, and
has the added benefit over custom metadata of being included in node status output:

{{<highlight text>}}
damien@support:~> nomad node status
ID        DC          Name                            Class          Drain  Eligibility  Status
e9d5cdfe  ca-central  nomad-client-ca-central-UgcT5Q  load-balancer  false  eligible     ready
67d7b064  ca-central  nomad-client-ca-central-4XMmYQ  <none>         false  eligible     ready
{{</highlight>}}

Fabio jobs can then be specified to run exclusively on `load-balancer` nodes with:

{{<highlight htcl>}}
constraint {
	attribute = "${node.class}"
	value     = "load-balancer"
}
{{</highlight>}}


### DNS Management

Once the `load-balancer` node is up and running an instance of Fabio, everything should
_technically_ be available on the internet, but it won't be very easy to reach without a domain
name. However, it would also be a pain to manually update a DNS management system with new records
every time your cluster changes.

Fortunately, DNS records can be considered just another part of your infrastructure, and can
therefore be provisioned with Terraform! This means that any time a new `load-balancer` node is
created or destroyed, a DNS record is created or destroyed along with it, automatically keeping your
domain name in sync with available load balancers.

To support this, I defined a Terraform module called
[`domain-address`](https://git.sr.ht/~damien/infrastructure/tree/master/terraform/domain-address),
which takes as input the domain, a name for the record, and a list of Linode instances. The
`linode_domain_record` resource can then be used to define `A` and/or `AAAA` records pointing to the
IPv4 and/or IPv6 addresses respectively:

{{<highlight htcl>}}
data "linode_domain" "d" {
  domain = var.domain
}

resource "linode_domain_record" "a" {
  for_each    = toset(terraform.workspace == "default" ? var.instances[*].ip_address : [])
  domain_id   = data.linode_domain.d.id
  name        = var.name
  record_type = "A"
  target      = each.value
}

resource "linode_domain_record" "aaaa" {
  for_each    = toset(terraform.workspace == "default" ? [for ip in var.instances[*].ipv6 : split("/", ip)[0]] : [])
  domain_id   = data.linode_domain.d.id
  name        = var.name
  record_type = "AAAA"
  target      = each.value
}
{{</highlight>}}

One thing to note here is the `terraform.workspace` check within the `for_each` line. This is to
support development flows that use [Terraform
workspaces](https://www.terraform.io/docs/state/workspaces.html), which can be useful for testing
cluster changes (such as OS upgrades) without affecting the existing deployment. DNS records are
global, so we use this check to ensure that they are only created within the default workspace and
aren't overwritten to point to a non-production cluster.

### Cert Renewals

The last step is to set up automatic SSL certificate renewal. If you don't need or want to serve
your website over HTTPS, then you can skip this step, but most websites should probably be served
securely and therefore will need SSL.

In addition to providing orchestration for always-on services, Nomad supports something akin to cron
jobs in the form of the
[`periodic`](https://www.nomadproject.io/docs/job-specification/periodic.html) stanza. With this, we
can write a Nomad job that executes our SSL renewal regularly so that its validity never lapses.

#### Getting the Certificate

The first step is deciding which SSL renewal service and tool to go with. [Let's
Encrypt](https://letsencrypt.org/) is the big name in this space because it's free and run by a
nonprofit, but that's not a hard requirement as long as whichever service you choose has APIs for
automatic renewal.

For tool, I decided to go with [acme.sh](https://github.com/acmesh-official/acme.sh), because it
provides a nice interface with minimal dependencies, though there are a number of [other
options](https://letsencrypt.org/docs/client-options/) available for any ACME-compatible service.

##### The Challenge

The ACME protocol requires you to be able to prove that you own the domain being renewed through a
[challenge](https://tools.ietf.org/html/rfc8555#section-8), with the two main options being HTTP
and DNS. HTTP challenges work by giving you some data and verifying its existence under
`http://<domain>/.well-known/acme-challenge/`; DNS challenges work similarly, but the
challenge expects the data to be available as a TXT record on the domain.

Due to the distributed nature of jobs running on Nomad, the HTTP challenge is not really viable, so
I recommend using the DNS challenge along with your DNS provider's API.

<!-- vim: set tw=100: -->
