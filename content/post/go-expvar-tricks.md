+++
date = "2016-07-26T23:29:01-05:00"
title = "Go Expvar Tricks"
draft = true
+++

# Introduction

The utility of Go's `expvar` package is not really given justice by the
package's concise description:

{{<highlight text>}}
Package expvar provides a standardized interface to public
variables, such as operation counters in servers. It exposes
these variables via HTTP at /debug/vars in JSON format.
{{</highlight>}}

What does that mean exactly, and why is it useful? A hint is given with
the phrase "operation counters in servers", but in this post I will touch
on some more concrete examples for making `expvar` work for you.

<!--more-->

# Hello Expvar

Unfortunately, the rest of the package's documentation is short on examples,
but fortunately it's not difficult to get up and running:

{{<highlight go>}}
package main

import (
    _ "expvar"
    "net/http"
)

func main() {
    http.ListenAndServe(":8080", nil)
}
{{</highlight>}}

Run this program and open `http://localhost:8080/debug/vars` in a browser
(or `curl`), and you should see a JSON blob containing two top-level keys:

1. `cmdline`: an array representing the command used to start the program.
(If run via `go run`, the executable will be contained inside some temporary
build directory.)
2. `memstats`: an object containing a bunch of memory statistics, whose
exact meaning is beyond the scope of this blog post.

...this information is a start, but it's not really what we want. How
do we go about adding our own data?

First, it's important to fully understand what's going on in the short
example above. `expvar` works by registering an HTTP handler with
`http.DefaultServeMux`; it does this on package initialization, so no
explicit call is necessary (note that the `_` before the package import
tells Go that we only want the package's side effect of initialization,
and have no plans to reference it directly). This happens before `main`
begins execution, at which point we just need to begin serving HTTP
requests. Providing `nil` as the second parameter to `http.ListenAndServe()`
is equivalent to passing `http.DefaultServeMux` explicitly, so any
requests to `/debug/vars` are correctly routed to the handler registered
by `expvar`.

Got all that? Let's go further.

## Supporting More Routers

`http.DefaultServeMux` is great and all, but I'm personally a big fan
of Gorilla's `mux` package, and given the array of router options available
today, `expvar` wouldn't be very useful if you had to sacrifice any freedom
in router choice in order to use it.

Since `expvar` only registers its endpoint with `http.DefaultServeMux`,
we'll have to get a little creative:

{{<highlight go>}}
package main

import (
    _ "expvar"
    "net/http"

    "github.com/gorilla/mux"
)

func main() {
    router := mux.NewRouter()
    router.Path("/debug/vars").Handler(http.DefaultServeMux)
    http.ListenAndServe(":8080", router)
}
{{</highlight>}}

This example is very similar, except we explicitly redirect any
requests made to `/debug/vars` to `http.DefaultServeMux`. Now we can
register the rest of our routes normally, and the `expvar` endpoint
will continue to work exactly the same as before.

Let's start adding our own data points.

# Adding Revision

One very useful piece of information to expose is your application's
revision, and is fairly simple to implement as it doesn't require any
changes during runtime. Exposing a new variable is quite simple:

{{<highlight go>}}
package main

import (
    "expvar"
    "net/http"

    "github.com/gorilla/mux"
)


func main() {
    expvar.NewString("revision").Set("abcd")

    router := mux.NewRouter()
    router.Path("/debug/vars").Handler(http.DefaultServeMux)
    http.ListenAndServe(":8080", router)
}
{{</highlight>}}

(Tip: one way to easily query for a single variable is to execute
`curl -s http://localhost:8080/debug/vars | jq .<variable>`, provided
you have curl and jq installed)

You should now see a new key called "revision" with the value "abcd".
Now all you have to do is manually update this hardcoded value each time
you deploy your application!

## Setting Revision on Startup

Obviously, manually updating a hardcoded string value for each and
every change is error prone and boring. A better way involves using
Go's linker to save the revision within the application as a variable.
This requires a small modification to the above program:

{{<highlight go>}}
package main

import (
    "expvar"
    "net/http"

    "github.com/gorilla/mux"
)

var REVISION string

func main() {
    expvar.NewString("revision").Set(REVISION)

    router := mux.NewRouter()
    router.Path("/debug/vars").Handler(http.DefaultServeMux)
    http.ListenAndServe(":8080", router)
}
{{</highlight>}}

When run normally, this will report revision as the empty string. However,
it's possible to pass a value for this variable on the command line at build
or run time (assuming your file is named `main.go`):

{{<highlight text>}}
$ go run -ldflags "-X main.REVISION=wxyz" main.go
{{</highlight>}}

When run this way, revision should be reported as `"wxyz"`. It's left as an
exercise to the reader to determine how to inject a more meaningful value
here based on your version control system (hint for git users: `git rev-parse HEAD`).
By using a build system like `make` to start your program, you can automate
this so that your program always reports the correct revision.

This type of `expvar` use is quite helpful, but let's see how to get it to
report on some more dynamic information.

# Reporting Metrics

Another very useful data point that can be exposed is the number of requests
that your site serves over time. In order to get this information, we need to build in
some middleware whose job is to keep track of it for us, so that we know that every
request is accounted for without having to duplicate the code for each handler.
Some frameworks come with their own methods for defining custom middleware, but for these
examples, I'm going to use `alice`, which is a 3rd-party package that makes it easy to
define a middleware chain.

Without using `expvar`, here's a naïve initial implementation that keeps track of
the number of hits to each available endpoint (Note that an index handler has been
added so that the example can be tested without hitting a 404):

{{<highlight go>}}
package main

import (
    "fmt"
    "net/http"

    "github.com/gorilla/mux"
    "github.com/justinas/alice"
)

var hits = make(map[string]int)

// hitCounter is a middleware handler that increments the hit counter
// for the request's method and URL.
func hitCounter(next http.Handler) http.Handler {
    return http.HandlerFunc(
        func(w http.ResponseWriter, r *http.Request) {
            key := fmt.Sprintf("%s %s", r.Method, r.URL.Path)
            hits[key]++

            next.ServeHTTP(w, r)
        },
    )
}

func indexHandler(w http.ResponseWriter, r *http.Request) {
    w.Write([]byte("This is the front page."))
}

func main() {
    router := mux.NewRouter()
    router.Path("/").HandlerFunc(indexHandler)
    http.ListenAndServe(":8080", alice.New(
        hitCounter,
    ).Then(router))
}
{{</highlight>}}

Spot the bug? This code has a glaring race condition in that `hits` is not
protected by any synchronization. Remember that Go spawns a new goroutine
for each incoming request, and if two requests come in at the same time,
modifying a global value like this without a mutex can lead to unexpected
results.

Let's kill two birds with one stone by utilizing an `expvar.Map`. Not only
does this expose the value for us through `/debug/vars`, but it's also
thread-safe because it does its own internal synchroniziation:

{{<highlight go>}}
package main

import (
    "expvar"
    "fmt"
    "net/http"

    "github.com/gorilla/mux"
    "github.com/justinas/alice"
)

var hits = expvar.NewMap("hits")

// hitCounter is a middleware handler that increments the hit counter
// for the request's method and URL.
func hitCounter(next http.Handler) http.Handler {
    return http.HandlerFunc(
        func(w http.ResponseWriter, r *http.Request) {
            key := fmt.Sprintf("%s %s", r.Method, r.URL.Path)
            hits.Add(key, 1)

            next.ServeHTTP(w, r)
        },
    )
}

func indexHandler(w http.ResponseWriter, r *http.Request) {
    w.Write([]byte("This is the front page."))
}

func main() {
    router := mux.NewRouter()
    router.Path("/").HandlerFunc(indexHandler)
    router.Path("/debug/vars").Handler(http.DefaultServeMux)
    http.ListenAndServe(":8080", alice.New(
        hitCounter,
    ).Then(router))
}
{{</highlight>}}

That is actually all there is to it. It can even be adjusted to give a rate
value, e.g. "hits per minute", by decrementing the value after the preferred
amount of time has passed:

{{<highlight go>}}
package main

import (
    "expvar"
    "fmt"
    "net/http"
    "time"

    "github.com/gorilla/mux"
    "github.com/justinas/alice"
)

var rates = expvar.NewMap("rates")

// hitCounter is a middleware handler that increments the hit counter
// for the request's method and URL.
func hitCounter(next http.Handler) http.Handler {
    return http.HandlerFunc(
        func(w http.ResponseWriter, r *http.Request) {
            key := fmt.Sprintf("%s %s", r.Method, r.URL.Path)
            rates.Add(key, 1)
            go func() {
                time.Sleep(1 * time.Minute)
                rates.Add(key, -1)
            }()

            next.ServeHTTP(w, r)
        },
    )
}

func indexHandler(w http.ResponseWriter, r *http.Request) {
    w.Write([]byte("This is the front page."))
}

func main() {
    router := mux.NewRouter()
    router.Path("/").HandlerFunc(indexHandler)
    router.Path("/debug/vars").Handler(http.DefaultServeMux)
    http.ListenAndServe(":8080", alice.New(
        hitCounter,
    ).Then(router))
}
{{</highlight>}}
