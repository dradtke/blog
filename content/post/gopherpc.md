+++
date = "2018-06-20"
title = "GopherJS and RPC over HTTP"
+++

[GopherJS](https://github.com/gopherjs/gopherjs) enables web development using
Go for both the backend server code _and_ frontend browser code. One of the neat
things this allows you to do, which the NodeJS community is all too happy to tell
you, is share code between the frontend and backend. However, JavaScript is a
dynamic language, and lacks many of the static analysis tools that Go provides.
By taking advantage of Go's static analysis, it is possible to develop HTTP
endpoints in the backend and automatically generate frontend code for calling
them, using Go models and types end-to-end. This is done with the help of a tool
I've written called [gopherpc](https://github.com/dradtke/gopherpc).

While the technique shown here could also be applied to plain HTTP handlers, I'm
going to instead opt for RPC over HTTP, since it lends itself more easily to the
type of static analysis we're interested in.

# RPC Over HTTP

Go's [net/rpc](https://golang.org/pkg/net/rpc/) package lays the basic
groundwork for RPC in Go. By defining and registering services with methods
following a well-defined pattern, any new methods are automatically made
available, and the runtime takes care of marshalling data to and from the method
call. [Gorilla's rpc](http://www.gorillatoolkit.org/pkg/rpc/v2) package extends
this idea to work over HTTP, which is very similar, but adds the `*http.Request`
as a required parameter for defined methods.

Here's how you define a simple Gorilla RPC server:

{{<highlight go>}}
package main

import (
        "log"
        "net/http"
        "strings"

        "github.com/gorilla/rpc/v2"
        "github.com/gorilla/rpc/v2/json"
)

type StringService struct{}

func (s StringService) Upper(r *http.Request, str *string, reply *string) error {
        *reply = strings.ToUpper(*str)
        return nil
}

func main() {
        s := rpc.NewServer()
        s.RegisterCodec(json.NewCodec(), "application/json")
        s.RegisterService(StringService{}, "")

        http.Handle("/rpc", s)

        if err := http.ListenAndServe(":8080", nil); err != nil {
                log.Fatal(err)
        }
}
{{</highlight>}}

This registers an RPC endpoint at `http://localhost:8080/rpc` with a JSON codec.
To access it, you need to send a specially-formatted POST request to it:

{{<highlight bash>}}
$ curl -X POST \
    -H 'Content-Type: application/json' \
    -d '{"method":"StringService.Upper", "params":["hello"], "id":1}' \
    http://localhost:8080/rpc
{{</highlight>}}

This command would get the following response:

{{<highlight text>}}
{"result":"HELLO","error":null,"id":1}
{{</highlight>}}

# Using with GopherJS

In order to use this RPC service from GopherJS, you can annotate it with a
`gopherpc:generate` comment, like this:

{{<highlight go>}}
// gopherpc:generate
type StringService struct{}

// add method definitions
{{</highlight>}}

GopherJS bindings to this service can then be generated with `gopherpc`:

{{<highlight bash>}}
$ go get github.com/dradtke/gopherpc/cmd/gopherpc
$ gopherpc -scan <pkg> -o <output>
{{</highlight>}}

`<pkg>` must reference the package where your RPC services are defined, and
`<output>` should be set to the path of the Go file to write. The GopherJS code
to call it then looks like this, where `<rpc>` references the package to which
`<output>` belongs:

{{<highlight go>}}
// +build js

package main

import (
    "github.com/dradtke/gopherpc/json"
    rpc <rpc>
)

func main() {
    client := rpc.Client{
        URL:       "http://localhost:8080/rpc",
        Encoding:  json.Encoding{},
    }

    result, err := client.StringService().Upper("hello")
    if err != nil {
        println("failed to call StringService.Upper: " + err.Error())
    } else {
        println(result) // should be "HELLO"
    }
}
{{</highlight>}}

Note how this results in a fully statically-compiled frontend binding for
asynchronously calling backend services. If a service method gets renamed, or
the types don't align between the backend and frontend code, it results in a
GopherJS compile error.

A more full example can be seen
[here](https://github.com/dradtke/gopherpc/tree/master/testdata).
