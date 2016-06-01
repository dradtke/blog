+++
date = "2016-05-31T23:10:28-05:00"
title = "js/template"
+++

One of my favorite packages in the Go standard library is
[html/template][htmltemplate]. Not only does it provide a solid templating
language equivalent to [text/template][texttemplate], but it ensures its
safety of any HTML or JavaScript you throw at it. Unfortunately,
it can be a little limiting when working with external JavaScript resources,
but there are a couple options for working around those limitations.

<!--more-->

Most websites like to separate the concerns of markup and scripting
by having separate `.html` and `.js` files for their project. However,
html/template always assumes that it's working with `.html` files.
JavaScript escaping is enabled whenever the template engine encounters
a `<script>` tag, but you can't pass it a pure JavaScript file without
running into a "malformed HTML" error. Fortunately, it's not too difficult
to trick the engine into properly parsing JavaScript sources.

There are two ways to add JavaScript code to an HTML page: embedded
directly, or referenced via an `src` attribute. The former may be useful
if your scripts are very small, but in a general sense, the latter is
usually the approach that you want, so that's the one that I'll show here.

The trick to getting html/template to properly parse your JavaScript code
is simply to wrap its contents in a `<script>` tag, then trim it off before
sending it back to the client:

{{<highlight go>}}
package main

import (
	"bytes"
	"fmt"
	"html/template"
	"io/ioutil"
	"net/http"
)

// ScriptFetcher is an HTTP handler that behaves similarly to a
// static file handler, except that it only serves JavaScript
// files, which it templates before sending to the client.
//
// In this example, the handler looks for a local JavaScript
// file by trimming off the leading slash, e.g.
// "GET /script/index.js" will look for "script/index.js".
func ScriptFetcher(w http.ResponseWriter, r *http.Request) {
    contents, err := ioutil.ReadFile(r.URL.Path[1:])
    if err != nil {
        // Kind of a sledgehammer as far as error-handling goes,
        // but it's good enough for the purposes of this example.
        http.Error(w, err.Error(), http.StatusInternalServerError)
        return
    }

    // Create a new template by wrapping the JavaScript contents
    // in an HTML <script> tag.
    t, err := template.New("").Parse(
        fmt.Sprintf("<script>%s</script>", string(contents)),
    )
    if err != nil {
        http.Error(w, err.Error(), http.StatusInternalServerError)
        return
    }

    // Execute the script against an in-memory buffer,
    // since we need to trim the </script> tag off the end of the
    // result, which requires knowing the total length of the
    // data.
    //
    // In a real-world situation, you'd probably want to
    // actually pass in some data value other than `nil`.
    var buf bytes.Buffer
    if err := t.Execute(&buf, nil); err != nil {
        http.Error(w, err.Error(), http.StatusInternalServerError)
        return
    }

    // Now the buffer contains our script result surrounded by the
    // <script> tag, so we need to trim that off before sending it
    // to the client.
    var (
        result = buf.Bytes()
        start  = len([]byte("<script>"))
        end    = len(result) - len([]byte("</script>"))
    )
    if _, err := w.Write(result[start:end]); err != nil {
    	// Poor man's logging.
    	fmt.Printf("error writing response: %s\n", err.Error())
    }
}
{{</highlight>}}


[htmltemplate]: https://golang.org/pkg/html/template/
[texttemplate]: https://golang.org/pkg/text/template/
