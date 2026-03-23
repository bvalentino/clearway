enum PreviewCSS {

    static let css = """
    * {
        margin: 0;
        padding: 0;
        box-sizing: border-box;
    }

    body {
        font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
        font-size: 16px;
        line-height: 1.6;
        color: #E0E0E0;
        background: transparent;
        margin: 0;
        padding: 20px 20px 60px;
        -webkit-font-smoothing: antialiased;
    }

    /* Headings */
    h1, h2, h3, h4, h5, h6 {
        font-weight: 700;
        line-height: 1.3;
        margin-top: 1.5em;
        margin-bottom: 0.5em;
        color: #F0F0F0;
    }
    h1:first-child, h2:first-child, h3:first-child { margin-top: 0; }
    h1 { font-size: 2em; }
    h2 { font-size: 1.5em; }
    h3 { font-size: 1.25em; }
    h4 { font-size: 1.1em; }
    h5, h6 { font-size: 1em; }

    /* Paragraphs */
    p {
        margin-bottom: 1em;
    }

    /* Links */
    a {
        color: #6699CC;
        text-decoration: none;
    }
    a:hover {
        text-decoration: underline;
    }

    /* Bold and italic */
    strong { color: #F0F0F0; }

    /* Code */
    code {
        font-family: "SF Mono", SFMono-Regular, Menlo, monospace;
        font-size: 0.85em;
        background: #2A2A2A;
        color: #E6736F;
        padding: 0.15em 0.35em;
        border-radius: 3px;
    }
    pre {
        background: #1E1E1E;
        border: 1px solid #333333;
        border-radius: 6px;
        padding: 1em;
        overflow-x: auto;
        margin-bottom: 1em;
    }
    pre code {
        background: none;
        color: inherit;
        padding: 0;
        border-radius: 0;
        font-size: 0.85em;
    }

    /* Blockquotes */
    blockquote {
        border-left: 3px solid #555555;
        padding-left: 1em;
        margin-left: 0;
        margin-bottom: 1em;
        color: #999999;
        font-style: italic;
    }
    blockquote p:last-child { margin-bottom: 0; }

    /* Lists */
    ul, ol {
        margin-bottom: 1em;
        padding-left: 1.5em;
    }
    li {
        margin-bottom: 0.25em;
    }
    li > ul, li > ol {
        margin-bottom: 0;
    }

    /* Task lists */
    ul.contains-task-list {
        list-style: none;
        padding-left: 0;
    }
    li.task-list-item {
        display: flex;
        align-items: baseline;
        gap: 0.4em;
    }
    li.task-list-item input[type="checkbox"] {
        margin: 0;
    }

    /* Tables */
    table {
        width: 100%;
        border-collapse: collapse;
        margin-bottom: 1em;
        font-size: 0.95em;
    }
    th, td {
        border: 1px solid #333333;
        padding: 0.5em 0.75em;
        text-align: left;
    }
    th {
        background: #252525;
        font-weight: 600;
        border-bottom-width: 2px;
    }
    tr:nth-child(even) td {
        background: #1E1E1E;
    }

    /* Horizontal rules */
    hr {
        border: none;
        border-top: 1px solid #333333;
        margin: 2em 0;
    }

    /* Images */
    img {
        max-width: 100%;
        height: auto;
        border-radius: 4px;
    }
    """
}
