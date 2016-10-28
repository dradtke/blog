+++
date = "2016-10-28T13:34:04-05:00"
title = "Beer and Concurrent HTTP Pipelines"
+++

This post is going to be a variation of the famous [pipelines and
cancellation](https://blog.golang.org/pipelines) Go blog post, modified for
crawling a website, and updated using `net/http`'s native support for request
contexts introduced in Go 1.7.

# Downloading Beer Recipes

My motivation for building a concurrent website crawler was to be able to
download a catalog of all public recipes on
[Brewtoad](https://www.brewtoad.com/). Each recipe can be individually exported
as XML, but from what I could tell there was no API to be able to download them
all. So, I got to crawlin'.

(Apologies in advance to the Brewtoad team for the harm I may have done to your
server by writing this post. Internet, please be gentle. <3)

# One at a Time

Recipes can be viewed by visiting the URL
`https://www.brewtoad.com/recipes?page=X&sort=rank`, where `X` is a page number
beginning at 1. Each page contains a series of links to specific recipes, and
the XML for that recipe can be downloaded by simply adding `.xml` to the end of
the URL. A simple first-pass, non-concurrent algorithm would then look like
this:

{{<highlight go>}}
for page := 1; ; page++ {
    resp, err := http.Get(fmt.Sprintf(
        "https://www.brewtoad.com/recipes?page=%d&sort=rank",
        page,
    ))
    if err != nil {
        panic(err)
    }

    // This line uses the `golang.org/x/net/html` package.
    doc, err := html.Parse(resp.Body)
    resp.Body.Close()
    if err != nil {
        panic(err)
    }
    
    // getRecipeLinks() implementation elided, but it walks the page,
    // extracts beer recipe links, and returns them as a slice.
    for _, recipeLink := range getRecipeLinks(doc) {
        beerXml, err := http.Get(
            "https://www.brewtoad.com" + recipeLink + ".xml",
        )
        if err != nil {
            panic(err)
        }

        // Beer recipe XML acquired!
    }
}
{{</highlight>}}

Since the majority of time spent running this code is waiting for the network
request to finish, it makes sense that concurrently executing multiple requests
at once would speed the whole process up.

# Concurrency: Take One

The natural way to concurrify this code is to kick off a new goroutine within
each iteration of the loop:

{{<highlight go>}}
for i := 1; ; i++ {
    go func(page int) {
        resp, err := http.Get(fmt.Sprintf(
            "https://www.brewtoad.com/recipes?page=%d&sort=rank",
            page,
        ))
        if err != nil {
            panic(err)
        }

        doc, err := html.Parse(resp.Body)
        resp.Body.Close()
        if err != nil {
            panic(err)
        }
        
        for _, recipeLink := range getRecipeLinks(doc) {
            go func(recipeLink string) {
                beerXml, err := http.Get(
                    "https://www.brewtoad.com" + recipeLink + ".xml",
                )
                if err != nil {
                    panic(err)
                }

                // Beer recipe XML acquired!
            }(recipeLink)
        }
    }(i)
}
{{</highlight>}}

You could then use a channel to collect all of your downloaded recipes into a
central location.

There's one problem with this approach, though:

{{<highlight text>}}
Get https://www.brewtoad.com/recipes?page=7136&sort=rank: dial tcp 192.237.224.29:443: socket: too many open files
{{</highlight>}}

or

{{<highlight text>}}
Get https://www.brewtoad.com/recipes?page=8120&sort=rank: dial tcp: lookup www.brewtoad.com: no such host
{{</highlight>}}

Exactly what error you get when you run that code may vary, but no computer
likes having thousands of HTTP requests sent off together in the blink of an
eye. While writing this post, I let that program run for a little bit too long,
and my computer's fan kicked into high gear. I wasn't able to get it back to
reasonable levels without `kill -9`.

This kind of "kick off a new goroutine for each computation you need, then wait
on the results" approach is fine for some workloads, but sending that many
concurrent HTTP requests is not one of them. So, a more nuanced approach is needed.

# Concurrency: Take Two

The natural way around this is to limit the number of goroutines that are active
at a time. This type of pattern is very common, and thanks to `sync.WaitGroup`,
very easy to implement:

{{<highlight go>}}
const numGoroutines = 50 // can adjust based on your hardware

var wg sync.WaitGroup
wg.Add(numGoroutines)

for i := 0; i < numGoroutines; i++ {
    go doSomething()
}

wg.Wait()
{{</highlight>}}

The next question then becomes the implementation of that `doSomething()`
function. Your goroutines will each need to download more than one page, and
they'll need some way of figuring out who should download which page.

One way to distribute the work is to "fan-out" by deciding which pages you
want to download, and then using a shared channel to send that input to
whichever goroutine gets it first:

{{<highlight go>}}
pc := make(chan int)

// Fill the input channel with the numbers 1-100 inclusive.
go func() {
    for i := 1; i <= 100; i++ {
        pc <- i
    }
    close(pc)
}()

for i := 0; i < numGoroutines; i++ {
    go func() {
        for {
            // Grab the next page off the channel. The `ok` value
            // will be false only if the channel has been closed,
            // which means there is no more input to process.
            page, ok := <-pc
            if !ok {
                break
            }

            // Download the page and collect its recipes.

            // Each recipe download on this page should be done
            // synchronously within this goroutine.
        }

        wg.Done()
    }()
}

wg.Wait()
{{</highlight>}}

With this change, you can now safely queue up as many pages of recipes as you'd
like, but your computer will no longer hate you since there will be at most
`numGoroutines` HTTP requests in flight at any given point in time.

# Adding Cancellation

One nice improvement is the ability to cancel all in-flight network requests.
This can be because you caught a SIGINT from the user, a certain amount of time
has passed, or any other reason. With the release of Go 1.7, this is super
easy to do since `http.Request` now supports native request-scoped contexts,
which include the ability to cancel at a moment's notice.

A simple cancellation context can be initialized like this:

{{<highlight go>}}
ctx, cancel := context.WithCancel(context.Background())
{{</highlight>}}

The `ctx` context then needs to be included with each request you kick off, so
the calls to `http.Get()` then become:

{{<highlight go>}}
req, err := http.NewRequest("GET", url, nil)
if err != nil {
    // handle err
}

http.DefaultClient.Do(req.WithContext(ctx))
{{</highlight>}}

# The Full Example

For those who want it, here's the full working code:

{{<highlight go>}}
package main

import (
    "context"
    "errors"
    "fmt"
    "io"
    "io/ioutil"
    "net/http"
    "strconv"
    "strings"
    "sync"
    "time"

    "golang.org/x/net/html"
)

func main() {
    // Do an initial request to determine how many pages of recipes there are
    // available to download.
    pageCount, err := getRecipePageCount()
    if err != nil {
        panic(err)
    }

    // Initialize the input (page count) channel and a cancelable request context.
    var (
        pc          = make(chan int)
        ctx, cancel = context.WithCancel(context.Background())
    )

    // Fill the input channel in a separate goroutine.
    go func() {
        for i := 1; i <= pageCount; i++ {
            pc <- i
        }
        close(pc)
    }()

    // Kick off the job. This returns two channels; one for receiving downloaded
    // recipes, and one for receiving errors.
    const numGoroutines = 50
    rc, errc := downloadRecipes(numGoroutines, ctx, pc)

    // Demonstration of pipeline cancellation. After 30 seconds, every goroutine
    // will be told to drop what it's doing and exit.
    go func() {
        <-time.After(30 * time.Second)
        fmt.Println("Telling everyone to clean up.")
        cancel()
    }()

    // Wait on input values from the spawned goroutines.
    for {
        // This block uses some clever channel tricks. If `ok` is false, it
        // means that the channel has been closed. A receive operation on a
        // closed channel immediately returns its type's zero value, but a
        // receive operation on a nil channel will never return. Once the
        // channel has been closed, we want to set it to nil to ensure that
        // that arm of the switch statement is never executed again.
        select {
        case recipe, ok := <-rc:
            if !ok {
                rc = nil
                break
            }

            // Do something with recipe. This will probably involve
            // saving it somewhere, unmarshaling it into a struct,
            // or both. Could be a good opportunity for another
            // pipeline!
            _ = recipe
            fmt.Println("Got a recipe.")

        case err, ok := <-errc:
            if !ok {
                errc = nil
                break
            }

            fmt.Println("Error: " + err.Error())
        }

        // Once both channels have been closed and set to nil, we need to
        // break out of the loop to avoid hanging indefinitely on no input.
        if rc == nil && errc == nil {
            break
        }
    }
}

// downloadRecipes spawns numGoroutines goroutines to download recipes from Brewtoad.
// The provided context can be used to cancel in-flight requests. The input channel
// provides the page numbers that should be downloaded. This method returns two channels:
// one for downloaded recipes in XML format, and one for any errors encountered.
func downloadRecipes(numGoroutines int, ctx context.Context, pc <-chan int) (<-chan string, <-chan error) {
    var (
        wg   sync.WaitGroup
        rc   = make(chan string)
        errc = make(chan error)
    )

    wg.Add(numGoroutines)

    for g := 0; g < numGoroutines; g++ {
        go func() {
            running := true
            for running {
                select {
                case page, ok := <-pc:
                    if !ok {
                        running = false
                        break
                    }

                    err := getRecipesForPage(ctx, rc, page)
                    // Don't send anything on the error channel if it was nil,
                    // or if cancellation was requested, since we're trying to
                    // abort everything anyway.
                    if err != nil && ctx.Err() != context.Canceled {
                        errc <- err
                    }

                // A receive event on this channel means that we're cancelled,
                // so we should stop what we're doing and exit the loop.
                case <-ctx.Done():
                    running = false
                }
            }
            wg.Done()
        }()
    }

    // Once all goroutines have finished, close the returned channels.
    go func() {
        wg.Wait()
        close(rc)
        close(errc)
    }()

    return rc, errc
}

// getRecipesForPage downloads a recipe page and sends each recipe found
// there along the provided channel.
func getRecipesForPage(ctx context.Context, rc chan<- string, page int) error {
    doc, err := downloadPage(ctx, page)
    if err != nil {
        return err
    }

    for _, link := range findRecipeLinks(doc) {
        r, err := downloadBeerXml(ctx, link)
        if err != nil {
            return err
        }

        beerXml, err := ioutil.ReadAll(r)
        r.Close()
        if err != nil {
            return err
        }

        rc <- string(beerXml)
    }

    return nil
}

// downloadPage downloads a recipe page from Brewtoad and parses it into
// an HTML document.
func downloadPage(ctx context.Context, page int) (*html.Node, error) {
    req, err := http.NewRequest("GET", fmt.Sprintf(
        "https://www.brewtoad.com/recipes?page=%d&sort=rank",
        page,
    ), nil)
    if err != nil {
        return nil, err
    }

    resp, err := http.DefaultClient.Do(req.WithContext(ctx))
    if err != nil {
        return nil, err
    }
    defer resp.Body.Close()
    return html.Parse(resp.Body)
}

// findRecipeLinks traverses an HTML document looking for beer recipe links.
func findRecipeLinks(doc *html.Node) (links []string) {
    var f func(*html.Node)
    f = func(n *html.Node) {
        defer func() {
            for c := n.FirstChild; c != nil; c = c.NextSibling {
                f(c)
            }
        }()

        if n.Type == html.ElementNode && n.Data == "a" {
            if classes, ok := getAttr(n.Attr, "class"); ok {
                for _, class := range strings.Fields(classes) {
                    if class == "recipe-link" {
                        href, _ := getAttr(n.Attr, "href")
                        links = append(links, href)
                        return
                    }
                }
            }
        }
    }
    f(doc)
    return
}

// downloadBeerXml downloads the XML for the provided recipe link. If no error
// is returned, then the io.ReadCloser must be closed by the caller in order to
// prevent a resource leak.
func downloadBeerXml(ctx context.Context, link string) (io.ReadCloser, error) {
    req, err := http.NewRequest("GET", "https://www.brewtoad.com"+link+".xml", nil)
    if err != nil {
        return nil, errors.New("failed to build beer xml request: " + err.Error())
    }

    resp, err := http.DefaultClient.Do(req.WithContext(ctx))
    if err != nil {
        return nil, errors.New("failed to get beer xml: " + err.Error())
    }
    return resp.Body, nil
}

// getRecipePageCount downloads the first page and checks the pagination to determine
// how many pages of recipes there are.
func getRecipePageCount() (int, error) {
    resp, err := http.Get("https://www.brewtoad.com/recipes?page=1&sort=rank")
    if err != nil {
        return 0, err
    }
    defer resp.Body.Close()

    doc, err := html.Parse(resp.Body)
    if err != nil {
        return 0, err
    }

    var pageCount int

    var f func(*html.Node)
    f = func(n *html.Node) {
        defer func() {
            if pageCount == 0 {
                for c := n.FirstChild; c != nil; c = c.NextSibling {
                    f(c)
                }
            }
        }()

        if n.Type == html.ElementNode && n.Data == "a" {
            if classes, ok := getAttr(n.Attr, "class"); ok {
                for _, class := range strings.Fields(classes) {
                    if class == "next_page" {
                        pageCount, err = strconv.Atoi(n.PrevSibling.PrevSibling.FirstChild.Data)
                        return
                    }
                }
            }
        }
    }
    f(doc)

    return pageCount, nil
}

// getAttr is a utility method for looking up an HTML element attribute.
func getAttr(attrs []html.Attribute, name string) (string, bool) {
    for _, attr := range attrs {
        if attr.Key == name {
            return attr.Val, true
        }
    }
    return "", false
}
{{</highlight>}}

And as a bonus, a couple type definitions for unmarshaling Brewtoad recipe
results into a more usable form:

{{<highlight go>}}
type RecipeList struct {
    Recipes []Recipe `xml:"RECIPE"`
}

type Recipe struct {
    XMLName    xml.Name `xml:"RECIPE"`
    Name       string   `xml:"NAME"`
    Type       string   `xml:"TYPE"`
    Brewer     string   `xml:"BREWER"`
    BatchSize  string   `xml:"BATCH_SIZE"`
    BoilSize   string   `xml:"BOIL_SIZE"`
    BoilTime   string   `xml:"BOIL_TIME"`
    Efficiency string   `xml:"EFFICIENCY"`
    Style      struct {
        StyleGuide     string `xml:"STYLE_GUIDE"`
        Version        string `xml:"VERSION"`
        Name           string `xml:"NAME"`
        StyleLetter    string `xml:"STYLE_LETTER"`
        CategoryNumber string `xml:"CATEGORY_NUMBER"`
        Type           string `xml:"TYPE"`
        OGMin          string `xml:"OG_MIN"`
        OGMax          string `xml:"OG_MAX"`
        FGMin          string `xml:"FG_MIN"`
        FGMax          string `xml:"FG_MAX"`
        ABVMin         string `xml:"ABV_MIN"`
        ABVMax         string `xml:"ABV_MAX"`
    } `xml:"STYLE"`
    Fermentables []struct {
        Name           string `xml:"NAME"`
        Origin         string `xml:"ORIGIN"`
        Type           string `xml:"TYPE"`
        Yield          string `xml:"YIELD"`
        Amount         string `xml:"AMOUNT"`
        DisplayAmount  string `xml:"DISPLAY_AMOUNT"`
        Potential      string `xml:"POTENTIAL"`
        Color          string `xml:"COLOR"`
        DisplayColor   string `xml:"DISPLAY_COLOR"`
        AddAfterBoil   string `xml:"ADD_AFTER_BOIL"`
        CoarseFineDiff string `xml:"COARSE_FINE_DIFF"`
        Moisture       string `xml:"MOISTURE"`
        DiastaticPower string `xml:"DIASTATIC_POWER"`
        Protein        string `xml:"PROTEIN"`
        MaxInBatch     string `xml:"MAX_IN_BATCH"`
        RecommendMash  string `xml:"RECOMMEND_MASH"`
        IBUGalPerLB    string `xml:"IBU_GAL_PER_LB"`
        Notes          string `xml:"NOTES"`
    } `xml:"FERMENTABLES>FERMENTABLE"`
    Hops []struct {
        Name          string `xml:"NAME"`
        Origin        string `xml:"ORIGIN"`
        Alpha         string `xml:"ALPH"`
        Beta          string `xml:"BETA"`
        Amount        string `xml:"AMOUNT"`
        DisplayAmount string `xml:"DISPLAY_AMOUNT"`
        Use           string `xml:"USE"`
        Form          string `xml:"FORM"`
        Time          string `xml:"TIME"`
        DisplayTime   string `xml:"DISPLAY_TIME"`
        Notes         string `xml:"NOTES"`
    } `xml:"HOPS>HOP"`
    Yeasts []struct {
        Laboratory  string `xml:"LABORATORY"`
        Name        string `xml:"NAME"`
        Type        string `xml:"TYPE"`
        Form        string `xml:"FORM"`
        Attenuation string `xml:"ATTENUATION"`
    } `xml:"YEASTS>YEAST"`

    // TODO: The <MISCS> tag.
}
{{</highlight>}}
