+++
date = "2017-03-10T15:27:58-06:00"
title = "Nomad Task Versioning"
+++

Lately I've been playing around with a lot of HashiCorp tools including
[Nomad](https://www.nomadproject.io/), their solution to application scheduling.
Despite its relative immaturity, there are a few things I really like about it:
straightforward, readable configuration syntax; ease of integration with other
HashiCorp tools; and flexible runtime drivers, including raw execution, meaning
you're not tied down to containers.

However, there's one area in which Nomad's documentation seems to be severely
lacking: versioning. Nomad provides seemingly good support for rolling updates,
but it's less clear how exactly to trigger one. In short, you need to make a
change to your job file, otherwise Nomad thinks there's nothing else to do, even
if the code you're asking it to run is different.

<!-- more -->

Let's make things a little more concrete. Say you have the following Go web
service that you want to deploy using Nomad:

{{<highlight go>}}
package main

import (
    "log"
    "net/http"
)

func index(w http.ResponseWriter, r *http.Request) {
    w.Write([]byte("Hello World!"))
}

func main() {
    http.HandleFunc("/", index)
    if err := http.ListenAndServe(":80", nil); err != nil {
        log.Fatal(err)
    }
}
{{</highlight>}}

You build this application into a standalone binary called `main` that you
then upload to a storage server. Now you can write a Nomad job spec that will
execute it:

{{<highlight text>}}
job "web" {
    region = "global"
    datacenters = ["dc1"]
    type = "service"

    group "webs" {
        task "frontend" {
            driver = "raw_exec"

            artifact {
                source = "http://<storage-server>/main"
            }

            config {
                command = "main"
                args = []
            }

            resources {
            }
        }
    }
}
{{</highlight>}}

_(Some notes about the above: the `raw_exec` driver needs to be explicitly enabled
in the Nomad options [and should only be used if Nomad itself is running under a
dedicated user], and `http://<storage-server>/main` represents an HTTP endpoint
that can download the main binary)_

Great! You have a web service up and running in Nomad. But then you realize that
you want to know the IP address of everyone who views your site, so you rewrite
it:

{{<highlight go>}}
package main

import (
    "log"
    "net/http"
)

func index(w http.ResponseWriter, r *http.Request) {
    log.Printf("New connection from %s", r.RemoteAddr)
    w.Write([]byte("Hello World!"))
}

func main() {
    http.HandleFunc("/", index)
    if err := http.ListenAndServe(":80", nil); err != nil {
        log.Fatal(err)
    }
}
{{</highlight>}}

You re-build it, upload the new `main` executable to your storage server, and
re-submit the job.

Then nothing happens.

That's because you haven't made a change to the job file, and Nomad doesn't know
that the remote artifact has changed. One way around this is to upload the
binary as `main2`, update your job file, and re-submit. Nomad then sees it's
supposed to be running `main2` instead of `main` and subsequently begins the
update process of downloading the new file and executing it. This works, but is
a very primitive solution and involves too much manual renaming and updating.

Let's do better.

## Job File Templating

The first step is to stop building your file as simply `main` and start adding a
version number to it. If you're using Git and running on something Unix-based,
then something like this will get the job done:

{{<highlight bash>}}
$ go build -o main:$(git rev-parse --short HEAD)
{{</highlight>}}

This produces a binary called something like `main:72b816f`, which can be
uploaded to the storage server as-is. Then you need to update your job file with
a placeholder for the version number (a proper templating language would be
better, but for this example we're just using `sed`):

{{<highlight text>}}
job "web" {
    region = "global"
    datacenters = ["dc1"]
    type = "service"

    group "webs" {
        task "frontend" {
            driver = "raw_exec"

            artifact {
                source = "http://<storage-server>/main:MAIN_VERSION"
            }

            config {
                command = "main:MAIN_VERSION"
                args = []
            }

            resources {
            }
        }
    }
}
{{</highlight>}}

Assuming this job file is named `web.nomad` and the versioned binary has been
uploaded, you can then update your application using a fairly simple shell
script:

{{<highlight bash>}}
#!/bin/bash

# Create a fresh temp directory
DIR=$(mktemp -d)

# Write a copy of web.nomad to the temp directory, but with
# all instances of MAIN_VERSION replaced with the actual version
sed "s/MAIN_VERSION/$(git rev-parse --short HEAD)/g" web.nomad \
  >$DIR/web.nomad

# Run the generated job file
nomad run $DIR/web.nomad

# Clean up
rm -r $DIR
{{</highlight>}}

## Wrapping Up

That wasn't too hard, but there are a couple things Nomad could do to make
this better:

1. **Templated job files**. This would provide a flexible way to inject values into
   the job file at the time `nomad run` is executed, which has any number of
   potential uses beyond application versioning.
2. **Better documentation**. The use case of updating an application's code with no
   other changes to the job file is mysteriously missing from Nomad's docs.
   Nomad should settle on a best practice for this and make sure it's
   well-documented.
3. Explicit support for artifact versioning? Not sure what exactly this would
   look like, and properly documenting an approach like mine would likely be
   enough, but it's such a central concept that it's worth considering.
