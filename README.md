# About

This repo contains instructions, configuration files and scripts that
will allow you to create a dashboard of the GovHack competition data
for teams, projects, regions, prizes etc.

![The Dashboard](Screenshot1.png)

# Requirements

* Bash
* Curl
* [CSVkit](https://github.com/wireservice/csvkit)
* [Elasticsearch](https://elastic.co/products/elasticsearch)
* [Logstash](https://elastic.co/products/logstash)
* [Kibana](https://elastic.co/products/logstas)

# How it works

The basic process is:

1. CSV export of GovHack Projects is downloaded (by bash script)
2. CSV is converted to JSON with CSVkit (by bash script)
3. JSON is read by Logstash, some processing performed and indexed
   into Elasticsearch

After that, the data is available in Elasticsearch and can be viewed
in Kibana.

# Setting it up

## Start Elasticsearch

First, you need an Elasticsearch cluster running some where.  It's
sufficient for the cluster to be a single Elasticsearch instance.  The
dataset is super-small, so even a micro instance (which are usually
free) on most cloud providers will be more than sufficient.

For more details on downloading, installing and running Elasticsearch,
see the
[official documentation](https://www.elastic.co/guide/en/elasticsearch/reference/2.3/_installation.html)

## Edit the Logstash config

Edit the Logstash config and change the `<somehost>:<someport>` to the
hostname and port on which Elasticsearch is running.  If you just
started Elasticsearch up on your own machine, this will be `localhost:9200`.

## Run the Bash script

The Bash script will downloaded the data, convert it and run Logstash
to index the data into Elasticsearch.  It's commented, so
[check it out](govhack.sh) to see how it works.  It will keep running
by simply sleeping and then re-exec'ing itself.  So once you start it
up, you're done!

## Start Kibana and import dashboards

Finally, you'll need to start up Kibana so you can view the pretty
visualisations. Follow the
[official documentation](https://www.elastic.co/guide/en/kibana/4.5/setup.html#explore). When
setting an index pattern, use `logstash-govhack-projects` and don't
select the **Index contains time-based events** checkbox.  _Note that
you could essentially just use the default index pattern and leave the
box checked, which will work, but if you start adding new indices and
other data, you may run into trouble._

Now, you'll want to import the existing dashboards and
visualisations.  See the last set of steps
[here](https://www.elastic.co/guide/en/kibana/4.5/managing-saved-objects.html).
Import the files in the [kibana](kibana) directory.  there are three
files there, for the saved search, the visualisations and the
dashboard.  Import all three.


## Marvel in the glorious data visualisations

At this point, data should be flowing into Elasticsearch and you
should be able to fire up your web browser, navigate to your Kibana
instance and open the **GovHack** dashboard and view the lovely data.


# How is the data processed and indexed?

Nearly all of the processing is done by Logstash.  There is an initial
step of converting the CSV file downloaded from the GovHack
hackerspace to JSON via CSVkit. What we end up with is a JSON
formatted file where each "line" (which we can call an _event_ or
_document_) is a single project in GovHack.  These lines contain a
number of _fields_, things like the project title, the team name, the
datasets used, etc.

Other than that, Logstash does the remaing cleaning and enriching. Let's walk through the
[Logstash config](logstash/logstash-govhack.conf).

First, we have an [input](https://www.elastic.co/guide/en/logstash/2.3/input-plugins.html) section.  This input section simply sets
up a [stdin](https://www.elastic.co/guide/en/logstash/2.3/plugins-inputs-stdin.html) input plugin to listen for events on the standard input
of the Logstash process.  We've also told Logstash to expect JSON
structured input, as we feed Logstash the JSON file we made with
CSVkit:

``` ruby
input {
    stdin {
        codec => json_lines
    }
}
```

Next we have a [filter](https://www.elastic.co/guide/en/logstash/2.3/filter-plugins.html) section, this is where we do several
manipulations to each line of JSON in the input (i.e., each project).
First off, we have a [mutate](https://www.elastic.co/guide/en/logstash/2.3/plugins-filters-mutate.html) filter, that, as the name suggests,
mutates each event in a number of ways:

``` ruby
    mutate {
        gsub => [
            "Used Datasets", "\n", "=",
            "Prizes", ", ([A-Z])", "=\1"
            ]
        split => {
            "Prizes" => "="
            "Used Datasets" => "="
        }
        strip => ["Used Datasets","Prizes","Project Description"]
        remove_field => ["@timestamp"]
    }
```

* We use a [gsub](https://www.elastic.co/guide/en/logstash/2.3/plugins-filters-mutate.html#plugins-filters-mutate-gsub) regular expression replacement to add in a unique
  terminator for the fields _Used Datasets_ and _Prizes_, both of
  which contain a list of values.
* We then [split](https://www.elastic.co/guide/en/logstash/2.3/plugins-filters-mutate.html#plugins-filters-mutate-split) these fields on that terminator so we add up with
  arrays of indivdual values in each of these fields instead of a
  long string mushed together.
* We [strip](https://www.elastic.co/guide/en/logstash/2.3/plugins-filters-mutate.html#plugins-filters-mutate-strip) leading and trailing whitespace from a number of fields,
  because humans.
* We [remove](https://www.elastic.co/guide/en/logstash/2.3/plugins-filters-mutate.html#plugins-filters-mutate-remove_field) the field _@timestamp_.  Logstash adds this automatically,
  assuming you are inserting time-based data.  This data isn't
  time-based, so we remove it.

We then check if the project has specified some datasets they are
using.  If so, we use a [grok](https://www.elastic.co/guide/en/logstash/2.3/plugins-filters-grok.html) filter to basically read the string and
extract out some extra individual fields:

``` ruby
    if [Used Datasets] != [] or [Used Datasets] != "[] @" {
        grok {
            match => { "Used Datasets" => "%{DATA:dataset}\[%{DATA:dataset_provider}\] @ %{GREEDYDATA:dataset_url}" }
        }
    }
```

The _Used Datasets_ field looks like:

```
Bureau of Meteorology [Bureau of Meteorology] @ http://www.bom.gov.au/catalogue/data-feeds.shtml
```

What we extract out with grok is the following:

```
<dataset> [<dataset_provider>] @ <dataset_url>
```

Each of _dataset_, _dataset\_provider_ and _dataset\_url_ then become
additional fields we store with each event.

We finally use the [fingerprint](https://www.elastic.co/guide/en/logstash/2.3/plugins-filters-fingerprint.html) filter to create a unique _id_ field
based on the team name and project title.  We do this as by default,
Elasticsearch will auto-assign documents an id.  Each time we reindex
this data, we would get different ids for the same documents and we
end up duplicating and bloating out our data.  With this unique id, we
can force Elasticsearch to update the existing document each time:

``` ruby
    fingerprint {
        key => "govhack"
        source => ["Team Name","Project Title"]
	concatenate_sources => true
        target => "[@metadata][id]"
    }
```

Finally we have our [output](https://www.elastic.co/guide/en/logstash/2.3/output-plugins.html) section.  This is pretty
straight-forward, we send data to Elasticsearch with the
[elasticsearch](https://www.elastic.co/guide/en/logstash/2.3/plugins-outputs-elasticsearch.html) output:

``` ruby
    elasticsearch {
        hosts => ["<somehost>:<someport>"]
        index => ["logstash-govhack-projects"]
        document_id => "%{[@metadata][id]}"
    }
```

And we print a dot for each event we index with the [stdout](https://www.elastic.co/guide/en/logstash/2.3/plugins-outputs-stdout.html):

```ruby
    stdout {
        codec => "dots"
    }
```

# To Do and Caveats

* I'm cheating^^^lazy and using the default Logstash dynamic mapping
  here. Ideally, you'd define your own mapping upfront for this index.
* For some of the fields, like _dataset_, _dataset\_provider_ and _prizes_ which are
  arrays, you lose the indentification what belongs to which due to
  the "flat" data structure applied.  So you can't do things like
  associate a particular dataset with a particular provider in an
  indivudal record. So ideally you'd either use some kind of nested
  structure for these fields or index a particular project and each
  dataset it is using as a separate document.

# License

For the actual configs, scripts and files in this repo, it's all under
an open Apache 2.0 license. The services used are covered by their
respective licenses, see the services themselves for their licenses.
