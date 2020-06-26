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

# Getting Started

A primary fixture in my setup is the use of a "support" server, which is a single VPS instance that
acts as the entrypoint for the rest of the cluster. Most of the infrastructure is provisioned with
Terraform and is designed to be easily replaceable; the support server is the lone instance which is
cared for as a [pet](http://cloudscaling.com/blog/cloud-computing/the-history-of-pets-vs-cattle/)
rather than cattle.

There are several important benefits of the support server:

1. Cluster members are provisioned with a random root password which is never exposed; access is
   only granted via SSH public keys, and never to `root`. Having a single access point into the
   cluster provides an easy way to tighten security. (_Technically_, my setup forwards my SSH agent
   whenever I `ssh` on to the support server and my keys are configured via Linode's dashboard, but
   this benefit still stands)
2. The support server acts as the guardian of the Certificate Authorities, and new certificates are
   only issued by making a request to the support server.
3. The support server maintains Terraform state. Setting up a backend is an option here as well, but
   for relatively simple uses like mine, it's easier to stick with the "local" backend on the
   support server.

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

# Enter Terraform

The SSL-specific setup is most of what needs to be done that can't be encoded in Terraform, due to
its sensitive nature. Almost everything else is Terraformable, which is fantastic for
reproducibility and state management.

There are many different ways to structure Terraform code, but I wanted to make sure that the
cluster components were as decomposed as possible. My cluster consists of the following node types:

1. `consul-server`
2. `vault-client`
3. `nomad-server`
4. `nomad-client`

Each of these has its own module, and for the most part are very similar. Servers are provisioned by
first running a [stackscript](https://www.linode.com/docs/platform/stackscripts/) on the server, and
then once that's done, Terraform takes over in order to do a number of custom configurations.

`nomad-client` bears some special mention, since it is likely the first instance type that you will
want to scale out, and it represents the nodes that will actually be running your applications.

TODO: talk load balancers and domain configuration
