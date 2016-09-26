+++
title = "Measuring C API Coverage with Go"
date = "2013-12-03"
+++

About a year ago I started working on an initial batch of Go bindings to the Allegro 5 game library, and while I like the idea of producing a fully-functional foreign-interface library, I didn't finish during the initial period of development, and the project lay dormant for months. Recently I began to revive it, but as soon as I did, I ran into a problem: how much had I already done? Which API calls still needed to be covered?

This blog post is about my solution to this question, which I implemented as a Go unit test. Go provides a unit testing framework with the standard library and tools, so it seemed like a natural fit for the problem of creating a Go program designed to report errors; in this case, each Allegro function that had not yet been implemented would be an error.

The process has a few fundamental steps:

1. Read the source of all files in the package and store it in memory.
2. Parse the C headers for a list of all function names that we need to implement.
3. For each function name, if it doesn't appear in the package source, report it as an error.

This is essentially akin to grepping over the package source. More intelligent solutions may be possible using Go's standard AST-parsing library, but this approach worked fine for my use case, and took a lot less time to develop.

Since the first and third steps are the shortest and easiest, I'll cover those first, and then dive into the hardest part, which is parsing the header files.

Reading the Package Source
--------------------------

Reading in the package source and storing it in memory is pretty easy; simply pass in the package source directory to this function:

{{<highlight go>}}
func getSource(packageRoot string) ([]byte, error) {
    var buf bytes.Buffer
    err := filepath.Walk(packageRoot, func(path string, info os.FileInfo, err error) error {
        if info.IsDir() && path != packageRoot {
            return filepath.SkipDir
        } else if !strings.HasSuffix(info.Name(), ".go") {
            return nil
        }
        data, err2 := ioutil.ReadFile(path)
        if err2 != nil {
            return err2
        }
        buf.Write(data)
        return nil
    })
    if err != nil {
        panic(err)
    }
    return buf.Bytes(), nil
}
{{</highlight>}}

Using Go's `filepath.Walk()` function makes this task an *ahem* walk in the park. The function starts by initializing a new `bytes.Buffer` instance, then uses `Walk()` to take care of iterating through each of its files. Because I kept all of the function calls within one package and used sub-packages for various modules, I wanted to make sure that subdirectories were skipped, which is the first thing that it checks for. The only other check is to ignore files not ending in `.go`, which aren't part of the source code. Assuming both of those tests pass, then the file is read in to memory and written to the buffer. Assuming all goes well, `Walk()` will exit with no error, and the buffer's current value is returned.

Well, that was easy.

Checking if a Function Appears in the Source
--------------------------------------------

This part is even easier:

{{<highlight go>}}
if !bytes.Contains(source, []byte("C."+name)) {
    // function is missing
}
{{</highlight>}}

where `source` is the source code as returned by `getSource()` and `name` is a string representing the name of the C function. `"C."` is prepended to it because that's how C functions are called from Go. If `bytes.Contains()` returns false here, then the call was not implemented.

That was even easier. Where's the catch?

Scanning the C Headers
----------------------

Here's where the tricky part is, but Allegro actually makes this surprisingly easy too. For reasons that I can only assume have to do with making them easier to parse by external tools, Allegro's function declarations use the C preprocessor to take this form:

{{<highlight c>}}
AL_FUNC(<type>, <name>, <params>);
{{</highlight>}}

At its simplest, parsing these is just a matter of using a regex like `AL_FUNC\((?P<type>.*), (?P<name>.*), \((?P<params>.*)\)\);` (`AL_FUNC` is replaced by different names for module headers, but everything else is the same), testing each line to see if it matches. If it does, extract the name and add it to the list of functions to check. If not, skip it.

{{<highlight go>}}
// Walk the header root (e.g. "/usr/include/allegro5"), collecting the source for each header.
// Note that the "internal" directory and non-header files are skipped.
filepath.Walk(headerRoot, func(header string, info os.FileInfo, err error) error {
    if info.IsDir() && info.Name() == "internal" {
        return filepath.SkipDir
    } else if info.IsDir() || !strings.HasSuffix(info.Name(), ".h") {
        return nil
    }
    data, err2 := ioutil.ReadFile(header)
    if err2 != nil {
        // report the error
        return nil
    }
    // find missing functions in data
    return nil
})
{{</highlight>}}

{{<highlight go>}}
// Loop through all of the lines in a header, reporting functions that don't appear in source.
regex := regexp.MustCompile(`AL_FUNC\((?P<type>.*), (?P<name>.*), \((?P<params>.*)\)\);`)
for _, line := range strings.Split(string(data), "\n") {
    line = strings.TrimSpace(line)
    vals := regex.FindStringSubmatch(line)
    if vals == nil {
        // no match
        continue
    }
    name := strings.TrimSpace(vals[2])
    if strings.HasPrefix(name, "_") {
        // function names starting with an underscore are private to Allegro
        continue
    }
    if !bytes.Contains(source, []byte("C."+name)) {
        // report missing function
    }
}
{{</highlight>}}

At the surface, this appears to be not much harder than the other steps, minus the difficulty of getting the regular expression correct. However, there's a catch: what happens if the function declaration spans multiple lines? There are several in the Allegro headers that do just that. Since this approach splits the string by line, it won't work, since the regex will fail when it only matches part of the line.

I'm no regex wizard, so there may still be a simpler way to do this using a more complicated regex, but my solution was to create a custom iterator using a channel, one that will concatenate all of the lines between the beginning and the end of a declaration. The approach essentially replaces the string with a channel, which is fed by a function in a separate goroutine that will loop through the string and send across "lines" of strings, taking care to make sure that all declarations fit onto a single line.

Here's the basics of what's going on:

{{<highlight go>}}
ch := make(chan string)
go func() {
    var buf bytes.Buffer
    lines := strings.Split(string(data), "\n")
    for i := 0; i < len(lines); i++ {
        line := strings.TrimSpace(lines[i])
        buf.WriteString(line)
        if strings.HasPrefix(line, "AL_FUNC") {
            for !strings.HasSuffix(line, ";") {
                i++
                line = strings.TrimSpace(lines[i])
                buf.WriteString(line)
            }
        }
        ch <- buf.String()
        buf.Reset()
    }
    close(ch)
}()

regex := regexp.MustCompile(`AL_FUNC\((?P<type>.*), (?P<name>.*), \((?P<params>.*)\)\);`)
for line := range ch {
    vals := regex.FindStringSubmatch(line)
    // ...
}
{{</highlight>}}

Notice how the for loop inside the goroutine checks to see if each line starts with `AL_FUNC`, and if it does, continues adding lines to the buffer until one ends with a semicolon, signaling the end of the declaration. Now we can safely loop through the channel and be assured that any `AL_FUNC` declarations will include the whole declaration.

That's a Wrap
-------------

The actual code in the final unit test is designed to take modules into account as well, and is therefore a little more complicated, but it follows the same basic principles. For the full source code, look at `coverage_test.go` in the root of the GitHub [repository](https://github.com/dradtke/go-allegro).
