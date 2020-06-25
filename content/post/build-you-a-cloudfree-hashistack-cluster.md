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
repo](https://git.sr.ht/~damien/infrastructure/). For the patient, read on.

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

The first step is to create a dedicated "support" VPS instance. This is the only instance that will
be created manually and cared for as a
[pet](http://cloudscaling.com/blog/cloud-computing/the-history-of-pets-vs-cattle/). All cluster
operations will be run from this server, and it will also play host to our Certificate Authorities.


{{<highlight go>}}
{{</highlight>}}
