{
    "type": "feed",
    "user": "testuser",
    "wiring": {
	"nodes": {
	    "the_input": {
		"type": "rsspoll",
		"configuration": {"href": "http://www.lshift.net/blog/feed",
                                  "interval": 30}
	    },
	    "the_transformer": {
		"type": "xslt",
		"configuration": {"stylesheet_url": "http://dev.lshift.net/matthew/sample.xslt"}
	    },
	    "the_regexp": {
		"type": "regexp_split",
		"configuration": {"regexp": "^.*Rabbit.*$",
				  "multiline": true,
				  "caseinsensitive": false,
				  "dotall": true
			         }
	    },
	    "the_output_pos": {
		"type": "webfeed",
                "configuration": {"title": "Test xslt with Rabbit"}
	    },
	    "the_output_neg": {
		"type": "webfeed",
                "configuration": {"title": "Test xslt without Rabbit"}
	    }
	},
	"edges": [
	    ["the_input", "output", "the_transformer", "input"],
	    ["the_transformer", "output", "the_regexp", "input"],
	    ["the_regexp", "positive", "the_output_pos", "input"],
	    ["the_regexp", "negative", "the_output_neg", "input"]
	]
    }
}
