+++
date = "2020-06-25"
title = "Build You a Cloud™-Free Hashistack Cluster"
draft = true
+++

"Hashistack" refers to a network cluster based on [HashiCorp](https://www.hashicorp.com/) tools, and
after spending some time on it off-and-on, the architecture of my own cluster (on which this blog is
running, among other personal projects) has finally stabilized. In this post I will walk you through
its high-level structure, some of the benefits provided, and hopefully show you how you can build a
similar cluster for your personal or professional projects.

For the impatient, everything I am talking about here is available publicly in my [infrastructure
repo](https://git.sr.ht/~damien/infrastructure/). For the more patient, read on.

## The Cloud™

The term "cloud" can be pretty ambiguous, but was popularized with the rise of services providing
features beyond just a Virtual Private Server, or VPS. In this post, I want to draw a distinction
between VPS providers and Cloud™ providers. While there are many different VPS providers, here I use
the term Cloud™ to refer to the big 3: AWS, Azure, and GCP.

There is nothing inherently wrong with building applications on the Cloud™, but almost by
definition, there is less to discuss here, especially with the recent launch of [HashiCorp Cloud
Platform](https://www.hashicorp.com/cloud-platform/). These services let you get up and running
quickly, but also often come with a hefty price tag. Sticking with VPS providers can save you money
and, in my opinion, is more fun.

## My Provider

My cluster is built on [Linode](https://www.linode.com/) because they offer openSUSE VPS images and
DNS management. However, this guide should still be relevant as long as your instances run an
operating system based on `systemd` and have `firewalld` installed.

# Table of Contents

The rest of this post is going to be broken down into the following sections:

1. [Getting Started](#getting-started)
2. [Safety First: Configuring TLS](#safety-first-configuring-tls)
3. Behind the Firewall
3. Provisioning with Terraform
4. Running a Website

## Getting Started

A primary fixture in my setup is the use of a "support" server, which is a single VPS instance that
acts as the entrypoint for the rest of the cluster. Most of the infrastructure is provisioned with
Terraform and is designed to be easily replaceable; the support server is the lone instance which is
cared for as a [pet](http://cloudscaling.com/blog/cloud-computing/the-history-of-pets-vs-cattle/)
rather than cattle.

There are several important benefits of using a support server:

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

## Safety First: Configuring TLS

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

Each of these folders have permissions that look like this:

{{<highlight text>}}
-r-------- 1 root root  227 Jul 23  2019 /etc/ssl/consul/ca-key.pem
-r--r--r-- 1 root root 1249 Jul 23  2019 /etc/ssl/consul/ca.pem
{{</highlight>}}

### CFSSL Configuration

CFSSL is a general-purpose CLI tool for managing TLS files, but it also has the
ability to run a server process for handling new certificate requests. That
requires defining a configuration file at `/etc/ssl/cfssl.json`:

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

{{<highlight text>}}
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

Running `multirootca` under systemd turns the support server into a central authority for issuing
new certificates, which is required in order to spin up new servers securely.

Issuing new certificates is done via [this
script](https://git.sr.ht/~damien/infrastructure/tree/master/scripts/issue-cert.sh), which is run
from each new node that needs certificates, and uses the CFSSL CLI to make a `gencert` request to
the running `multirootca` service. Like the support server, certs and keys all live under
`/etc/ssl`, grouped by application name.

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
