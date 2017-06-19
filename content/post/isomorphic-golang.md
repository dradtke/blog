+++
date = "2017-04-28T10:33:15-05:00"
title = "Isomorphic Golang"
draft = true
+++

One of the big reasons for Node.js' popularity, and arguably its single biggest
selling point, is its ability to use the same programming language for both
frontend and backend programming. Despite the fact that that language is indeed
[JavaScript](https://www.destroyallsoftware.com/talks/the-birth-and-death-of-javascript),
using the same technology for client and server programming carries a number of
benefits, including less cognitive overhead as a result of context switching,
and more straightforward data serialization.

However, JavaScript is still JavaScript, but there are more `${LANGUAGE}` to
JavaScript transpilers today than ever before, meaning that other languages are
now able to begin taking advantage of these benefits as well.

In this post, I want to demonstrate one way to do that with
[Go](https://golang.org/) by building a simple React-style counter using a
virtual DOM and 100% `html/template`-driven UI's.

(For the impatient, a link to the final working example can be found at the
bottom of the page)

# Setting Up

For demonstrative purposes, the project structure will remain quite simple:

```
.
├── main.go
├── static
│   ├── ...
└── views
    └── ...
```

At a high level, `main.go` is our server code, `static` contains public assets,
and `views` contains other frontend code.

Let's start with a super-simple Go server. This server only does two things:
renders `views/index.html` at the top level, and serves files under `static/`
using a prefix:

```go
package main

import (
    "fmt"
    "html/template"
    "net/http"
)

var serverTemplates *template.Template

func main() {
    // Parse server templates.
    serverTemplates = template.Must(
        template.New("").ParseFiles("views/index.html"),
    )

    // Set up HTTP handlers.
    http.HandleFunc("/", index)
    http.Handle("/static/", http.FileServer(http.Dir(".")))

    // Serve incoming requests.
    fmt.Println(" -- Listening  on port 8080 --")
    if err := http.ListenAndServe(":8080", nil); err != nil {
        panic(err)
    }
}

func index(w http.ResponseWriter, r *http.Request) {
    // Render index.html.
    err := serverTemplates.ExecuteTemplate(w, "index.html", nil)
    if err != nil {
        fmt.Println(err)
    }
}
```

And some very simple markup:

```html
<html>
  Hello, Go!
</html>
```

Run this program and you should be able to see this at [http://localhost:8080/](http://localhost:8080/):

{{< figure src="/images/isomorphic-golang/hello-go.png" class="regular" >}}

### Loading Some JavaScript

Let's toss some JavaScript into the mix. Here's a very simple example of a
GopherJS script, saved as `views/index.go`:

```go
// +build js

package main

import (
        "github.com/gopherjs/gopherjs/js"
)

func main() {
        js.Global.Call("alert", "Hello GopherJS!")
}
```

Assuming GopherJS is installed, you can build this with `gopherjs build
--output=static/index.js views/index.go`, then reference the result in
`views/index.html`:

```html
<html>
  Hello, Go!
  <script src="/static/index.js"></script>
</html>
```

Now reload the page and you should see an alert:

{{< figure src="/images/isomorphic-golang/alert.png" class="regular" >}}

Great, now we're able to write Go code and execute it as client-side JavaScript.
In order to display something more meaningful than an alert, we'll need to
introduce some templating.

# Client-Side Templates

A quick look at [GopherJS' compatibility
table](https://github.com/gopherjs/gopherjs/blob/master/doc/packages.md) shows
us that `html/template` is fully supported, which means that it can be used to
render templates client-side as well as server-side.

An aside for those not very familiar with React or Virtual DOMs: the benefit
of this approach is that you can implement your UI in terms of what it
should look like given some predefined state, rather than make ad-hoc updates
based on user input. This makes the interface much easier to reason about as it
grows in complexity.

We can verify that client-side templates do indeed work by modifying our
"JavaScript" (note the additional dependency on our DOM library):

```go
// +build js

package main

import (
    "bytes"
    "html/template"

    "honnef.co/go/js/dom"
)

var t = template.Must(
    template.New("").Parse(`Hello, <code>html/template</code>!`),
)

func main() {
    var buf bytes.Buffer
    if err := t.Execute(&buf, nil); err != nil {
        panic(err)
    }
    dom.GetWindow().Document().GetElementsByTagName("html")[0].
        SetInnerHTML(buf.String())
}
```

With this change, the page should display "Hello, Go!" briefly before switching
to "Hello, html/template!". The reason for the delay is that the HTML page loads
before the JavaScript runs, and then the JavaScript needs to parse our template,
execute it to a buffer, then update the DOM to use that result.

### Problem #1: Writing Templates as an Inline String

The above example is a little contrived in that the template is defined inline.
Once your template starts spanning more than one line, it becomes helpful to be
able to edit it as if it were any other file. To do that, we need to update our
server to be able to handle that. There are two options:

0. Embed client templates in the HTML as a `<script>` tag, then grab that value
   from the DOM.
0. Serve client templates as separate assets under `static/` and make a separate
   request to get the value.

With the advent of HTTP/2, option 2 may end up being an appealing option, but
for this post I'm going to stick with option 1.

Regardless of the approach taken, the first step is to parse the client
templates to make them available for use:

```go
package main

import (
    "bytes"
    "fmt"
    "html/template"
    "io/ioutil"
    "net/http"
    "path/filepath"
)

var (
    serverTemplates *template.Template
    clientTemplates map[string]string
)

func main() {
    // Parse templates.
    serverTemplates = template.Must(
        template.New("").ParseFiles("views/index.html"),
    )
    clientTemplates = parseClientTemplates("views/counter.tmpl")

    // Set up HTTP handlers.
    http.HandleFunc("/", index)
    http.Handle("/static/", http.FileServer(http.Dir(".")))

    // Serve incoming requests.
    fmt.Println(" -- Listening  on port 8080 --")
    if err := http.ListenAndServe(":8080", nil); err != nil {
        panic(err)
    }
}

// parseClientTemplates parses a set of client templates. Client
// templates recognize two kinds of delimeters: standard {{ }}
// delimeters indicate one-time changes to make to the template
// at startup, and [[ ]] delimeters are used for dynamic updates
// to the UI.
func parseClientTemplates(filenames ...string) map[string]string {
    ts := make(map[string]string)
    var buf bytes.Buffer
    for _, filename := range filenames {
        buf.Reset()
        b, err := ioutil.ReadFile(filename)
        if err != nil {
            panic(err)
        }
        t := template.Must(template.New("").Parse(string(b)))
        if err := t.Execute(&buf, nil); err != nil {
            panic(err)
        }
        name := filepath.Base(filename)
        ts[name] = buf.String()
    }
    return ts
}

func index(w http.ResponseWriter, r *http.Request) {
    // Render index.html.
    err := serverTemplates.ExecuteTemplate(w, "index.html", nil)
    if err != nil {
        fmt.Println(err)
    }
}
```

Client templates are first rendered as normal templates, which allows some
flexibility in their definition and adds the ability to embed server-side values
if desired, and then saved to a map. The idea is that the template contents will
be written out as part of the HTML, and then parsed client-side.

To enable them to be written out as part of the HTML, we'll define a new
template function:

```go
funcs := template.FuncMap{
    "embedtemplate": func(name, id string) (template.HTML, error) {
        s, ok := clientTemplates[name]
        if !ok {
            return template.HTML(""), errors.New(
                "embedtemplate: client template not found: " + name,
            )
        }
        return template.HTML(
            fmt.Sprintf(
                `<script type="text/template" id="%s">%s</script>`,
                id, s,
            ),
        ), nil
    },
}
```

The `serverTemplates` definition line then needs to be modified slighlty to make
use of the functions:

```go
serverTemplates = template.Must(
    template.New("").Funcs(funcs).ParseFiles("views/index.html"),
)
```

Now we can use our `embedtemplate` function to embed the template into our
markup:

```html
<html>
  {{embedtemplate "counter.tmpl" "counterTemplate"}}
  <script src="/static/index.js"></script>
</html>
```

This creates a tag with id `counterTemplate` whose contents we can read to get
the template, so the previous example with the hard-coded template can be
updated to something like this:

```go
tmpl := dom.GetWindow().Document().GetElementByID("counterTemplate")
t := template.Must(template.New("").Parse(tmpl.InnerHTML()))
```

BAM! Client-side `html/template` templates.

### Problem #2: Handling Updates

Now that we're able to render a client-side template, we need some way for it to
react to changes in state. I like to start by defining a `State` struct in each
script to define the state for that page; in the case of a counter, it's pretty
simple:

```go
type State struct {
    Count int
}
```

An instance of this struct can be passed in to the template's execution to
control the display. For example, here's really all we need for the client
template:

```html
<button type="button" name="decrement" onclick="UpdateCount(-1)">
  -1
</button>

[[.Count]]

<button type="button" name="increment" onclick="UpdateCount(1)">
  +1
</button>
```

Now we need to update our script to be able to repeatedly render this. I like
creating a wrapper function of sorts that takes a template and a target element
id, and returns a simple function that performs that render when called:

```go
// +build js

package main

import (
    "bytes"
    "html/template"

    "github.com/gopherjs/gopherjs/js"
    "honnef.co/go/js/dom"
)

type State struct {
    Count int
}

var (
    render func()
    state  = &State{}
)

// run is called when main is entered, but it's executed in a new
// goroutine to prevent any possible hangups in the browser UI.
func run() {
    tmpl := dom.GetWindow().Document().GetElementByID(
        "counterTemplate",
    )
    if tmpl == nil {
        panic("template counterTemplate not found")
    }
    t := template.Must(
        template.New("").Delims("[[", "]]").Parse(tmpl.InnerHTML()),
    )

    // Define a global method that the counter can call.
    js.Global.Set("UpdateCount", js.MakeFunc(UpdateCount))

    // Create the render function.
    render = renderFunc(t, "counter")
    render()
}

// UpdateCount modifies the count according to the first argument,
// then rerenders.
func UpdateCount(this *js.Object, arguments []*js.Object) interface{} {
    state.Count += arguments[0].Int()
    render()
    return nil
}

// renderFunc generates a rendering function which, when called,
// renders t into the element with the given id.
func renderFunc(t *template.Template, id string) func() {
    // Look up the target element and panic if it doesn't exist.
    target := dom.GetWindow().Document().GetElementByID(id)
    if target == nil {
        panic("target with id does not exist: " + id)
    }

    var buf bytes.Buffer

    // Return a function that performs the render.
    return func() {
        buf.Reset()
        if err := t.Execute(&buf, state); err != nil {
            panic(err)
        }
        target.SetInnerHTML(buf.String())
    }
}

func main() {
    go run()
}
```

Note that this requires an empty div with id `counter` to be added to the HTML
page, which serves as the anchor where the counter gets rendered.

The last thing is to make the above approach more efficient. The render() method
uses `SetInnerHTML()` because it's easy, but that requires rerendering the
entire contents of the `counter` div. In an ideal world, when the counter gets
updated, the *only* thing that gets updated in the DOM is the representation of
its value. The solution to that is to use a virtual DOM.

One such option is [vdom](https://github.com/albrow/vdom). How it works is that
you do one initial render with `SetInnerHTML()`, and then subsequent renders
calculate the difference between the virtual DOM and the actual one and only
make the necessary updates. Integrating the virtual DOM simply requires an
update to `renderFunc()`:

```go
// renderFunc generates a rendering function which, when called,
// renders t into the element with the given id. It also does an
// initial render, which means the returned function only needs
// to be called when state changes.
func renderFunc(t *template.Template, id string) func() {
    // Look up the target element and panic if it doesn't exist.
    target := dom.GetWindow().Document().GetElementByID(id)
    if target == nil {
        panic("target with id does not exist: " + id)
    }

    // Render the template for initial display.
    var buf bytes.Buffer
    if err := t.Execute(&buf, state); err != nil {
        panic("failed to execute client template: " + err.Error())
    }

    // Generate the initial virtual DOM tree, which will be used for
    // diffing later.
    tree, err := vdom.Parse(buf.Bytes())
    if err != nil {
        panic("failed to parse vdom tree: " + err.Error())
    }

    // Initial render. This is the only time SetInnerHTML() is used
    // on the target.
    target.SetInnerHTML(buf.String())

    return func() {
        // We're rerendering. Clear the buffer for reuse and execute
        // the template.
        buf.Reset()
        if err := t.Execute(&buf, state); err != nil {
            panic("failed to execute client template: " + err.Error())
        }

        // Generate a new virtual DOM tree based on the results of
        // the execution.
        newTree, err := vdom.Parse(buf.Bytes())
        if err != nil {
            panic("failed to parse vdom tree: " + err.Error())
        }

        // Determine what changes need to be made to the DOM.
        patches, err := vdom.Diff(tree, newTree)
        if err != nil {
            panic("failed to diff vdom: " + err.Error())
        }

        // Patch the DOM.
        if err := patches.Patch(target); err != nil {
            panic("failed to patch vdom: " + err.Error())
        }

        // Update the virtual DOM so that future diffs work as
        // expected.
        tree = newTree
    }
}
```

{{< figure src="/images/isomorphic-golang/counter.png" class="regular" >}}

Clicking on the -1 and +1 buttons will now do what you expect by updating the
number between them.

# One Level Deeper: Server-Side Rendering


Full source code (including server-side rendering) can be found
[here](https://github.com/dradtke/isomorphic-golang).

<!-- vim: set tw=80: -->
