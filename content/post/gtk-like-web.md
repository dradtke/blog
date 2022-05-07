+++
date = "2022-05-06"
title = "Building GTK Applications with a Web Deployment Model"
draft = true
+++

The modern web, broadly, consists of two distinct innovations: 1) the technology for rendering and
interacting with web pages (also known as the trifecta of HTML, CSS, and Javascript), and 2) the
client-server model for deploying those web pages, which allows application behavior to be modified
without having to push an update to every client.

Web rendering and interaction technology is widely used, both on the web and off. Electron and React
Native, for example, take the web technology stack and deploy it to your desktop or phone,
respectively, with no client-server interaction necessary.

Client-server application deployment, by contrast, is not widely used outside of the web in which it
originated; it is used for API endpoints with which applications may interact, but not for the
applications themselves. Alternative stacks, such as GTK (which is the focus of this post), are only
commonly used as client-only applications. Application logic runs directly on the client machine,
and any update requires users to download and install the new version.

In this post, I want to demonstrate a proof-of-concept GTK application using the client-server
deployment model pioneered by the web.

## Why?

Mainly because web browsers are, first and foremost, document renderers; their role as application
runtimes came much later. JavaScript was famously invented by Brendan Eich in just [10
days](https://thenewstack.io/brendan-eich-on-creating-javascript-in-10-days-and-what-hed-do-differently-today/),
and the rate at which new frameworks are released has caused many developers to suffer from
[JavaScript fatigue](https://auth0.com/blog/how-to-manage-javascript-fatigue/). This deluge of
frontend frameworks largely stems from browsers being designed back in the 90's to do one thing, and
now being used to do so much more.

Development stacks such as GTK were built by design to run _applications_, and not just to deliver
documents. As a result, many features that a web application would need to import dependencies for
come for free.

However, GTK applications lack the web's deployment model (i.e. the second innovation mentioned in
the first paragraph). The web's model is great because it allows applications to receive updates
that users don't need to install. As soon as an update is made live, everyone immediately has access
to it (after a refresh, of course).

It is worth noting that the intended audience of this post is, primarily, teams that are building
internal applications as part of their tooling. While there is no technical reason that this
technology couldn't be used for consumer-facing applications, it is unrealistic to expect your
average consumer to download a separate "browser" with minimal features to access certain
"websites." However, for teams with relatively little web development experience that want to build
internal applications, the approach I outline here ensures that updates are easy, everyone is
guaranteed to be running the same version, and users will only have to download the client
application once.

<!-- vim: set tw=100: -->
