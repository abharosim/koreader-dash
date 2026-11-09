-- Run: scripts/test.sh
local Markdown = dofile("plugin/dash.koplugin/dash_markdown.lua")

local failures, passed = 0, 0

local function check(name, actual, expected)
    if actual == expected then
        passed = passed + 1
        print("ok    " .. name)
    else
        failures = failures + 1
        print(string.format("FAIL  %s\n      expected %q\n      got      %q", name, tostring(expected), tostring(actual)))
    end
end

local function has(name, html, fragment)
    check(name, html:find(fragment, 1, true) ~= nil and fragment or html, fragment)
end

local html = Markdown.toHtml

check("headings", html("# One\n### Three ###"), "<h1>One</h1>\n<h3>Three</h3>")
check("paragraph lines join", html("one\ntwo\n\nthree"), "<p>one\ntwo</p>\n<p>three</p>")
check("bold, italic, strike", html("**b** *i* _u_ ~~s~~"), "<p><strong>b</strong> <em>i</em> <em>u</em> <s>s</s></p>")
check("underscores inside words stay", html("my_var_name"), "<p>my_var_name</p>")
check("inline code isn't formatted", html("`**not bold** <b>`"), "<p><code>**not bold** &lt;b&gt;</code></p>")
check("links show their text", html("[the docs](http://x.com)"), "<p><u>the docs</u></p>")
check("images show their alt text", html("![a chart](c.png)"), "<p>[a chart]</p>")
check("Chinese passes through", html("**小雨** 18°"), "<p><strong>小雨</strong> 18°</p>")
check("hard line break", html("one  \ntwo"), "<p>one<br/>\ntwo</p>")

check("raw HTML is shown, not run",
    html('<script>alert(1)</script> <img src="file:///etc/passwd"> & AT&T'),
    "<p>&lt;script&gt;alert(1)&lt;/script&gt; &lt;img src=&quot;file:///etc/passwd&quot;&gt; &amp; AT&amp;T</p>")

check("fenced code keeps text exactly",
    html('```lua\nlocal x = "<b>" -- **no**\n  indented\n```'),
    '<pre><code>local x = &quot;&lt;b&gt;&quot; -- **no**\n  indented</code></pre>')
check("unclosed fence runs to the end", html("```\ncode"), "<pre><code>code</code></pre>")

check("bullet list", html("- one\n- two"), "<ul>\n<li>one</li>\n<li>two</li>\n</ul>")
check("ordered list keeps its start", html("3. three\n4. four"), '<ol start="3">\n<li>three</li>\n<li>four</li>\n</ol>')
check("nested list",
    html("- one\n  - inner\n- two"),
    "<ul>\n<li>one\n<ul>\n<li>inner</li>\n</ul></li>\n<li>two</li>\n</ul>")
check("loose list uses paragraphs",
    html("- one\n\n- two"),
    "<ul>\n<li><p>one</p></li>\n<li><p>two</p></li>\n</ul>")
check("regression: a loose list stays one list",
    html("- one\n\n- two\n\n- three"):gsub("[^u]", ""):len(), 2)
check("list then paragraph", html("- one\n\nafter"), "<ul>\n<li>one</li>\n</ul>\n<p>after</p>")

check("blockquote", html("> **quoted**\n> more"), "<blockquote><p><strong>quoted</strong>\nmore</p></blockquote>")
check("horizontal rule", html("above\n\n---\n\nbelow"), "<p>above</p>\n<hr/>\n<p>below</p>")

check("table",
    html("| Name | **Value** |\n|---|:-:|\n| a | `1` |\n| b |"),
    "<table><tr><th>Name</th><th><strong>Value</strong></th></tr>"
    .. "<tr><td>a</td><td><code>1</code></td></tr><tr><td>b</td><td></td></tr></table>")

has("mixed document keeps every part",
    html("# Report\n\nIntro.\n\n## Results\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n- done\n\n```\nx\n```"),
    "<h2>Results</h2>")
check("empty body", html(""), "")
check("Windows line endings", html("# A\r\n\r\ntext"), "<h1>A</h1>\n<p>text</p>")

local big = string.rep("## Part\n\nSome **bold** text.\n\n- a\n- b\n\n", 3000)
local started = os.clock()
local big_html = html(big)
check("a 100 KB body converts", #big_html > #big, true)
check("and converts in under a second", os.clock() - started < 1, true)

local preview = Markdown.preview
check("preview strips Markdown",
    preview("# Build failed\n\n**Tests** failed in [CI](http://x).\n\n- step one"),
    "Build failed Tests failed in CI. step one")
check("preview skips code fence markers and table dividers",
    preview("```\ncode\n```\n| a | b |\n|---|---|"), "code a b")
check("preview keeps snake_case", preview("call my_func now"), "call my_func now")
check("preview truncates with an ellipsis", preview(string.rep("word ", 100), 20), "word word word wo…")
check("preview never splits a Chinese character",
    preview(string.rep("雨", 10), 10), "雨雨…")
check("truncation keeps a whole character at the boundary", Markdown.truncateUtf8("ab雨", 5), "ab雨")
check("truncation drops a partial character", Markdown.truncateUtf8("ab雨", 4), "ab")

print(string.format("\n%d passed, %d failed", passed, failures))
os.exit(failures == 0 and 0 or 1)
