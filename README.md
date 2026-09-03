# GeoSCADA-Schema-Tree

Generate an interactive, self-contained HTML view of the **Geo SCADA** object-model
(class) hierarchy by crawling the schema pages served at `https://<host>/schema/<ClassName>`.

Geo SCADA exposes its object model as XML: each class page (for example
`https://localhost/schema/CDBObject`) lists the class's **sub-classes**, plus the
configuration fields, data fields, aggregates, methods and alarm conditions that the
class introduces. This script walks that hierarchy from a chosen root class downwards
and renders it as a collapsible tree with a per-class details panel.

## Example

A pre-generated sample is included: **[Example.SchemaTree.html](Example.SchemaTree.html)** &mdash; a full
crawl from `CDBObject`. GitHub won't render HTML in the browser, so download the file (or use the raw
view) and open it locally to explore the tree, details panel and search without needing a Geo SCADA
server to hand.

## Features

- **Class tree** &mdash; the full sub-class hierarchy from a root class (default `CDBObject`),
  collapsible, with direct/total descendant counts.
- **Friendly names** &mdash; creatable classes carry a human-friendly name (e.g. `CAccumulatorInteg`
  &rarr; *Accumulator Integrator*), shown as subtext and included in search.
- **Details panel** &mdash; click a class name to slide out a panel showing the members
  **defined on that class**:
  - Configuration Fields & Data Fields (type, read-only, OPC property, referenced table,
    description, enum values)
  - Aggregates
  - Methods (with arguments and the return value marked)
  - Alarm Conditions (with sub-conditions)

  Referenced tables and base classes are clickable to jump to them; a link back to the raw
  schema page is provided. Clicking the &#9654; twisty still expands/collapses the tree.
- **Search** &mdash; filters by class name, friendly name **and** each class's own member content
  (field names, display names, descriptions, method/argument names, aggregate tables, alarm
  names and sub-conditions), revealing matches with their ancestors.
- **Self-contained output** &mdash; a single HTML file with no external dependencies; the class
  data is embedded as JSON and the panel is rendered client-side.

> Members are shown **as defined on each class** (matching its schema page one-to-one),
> not merged with inherited members from ancestor classes. Use the clickable **base** link in
> the panel header to walk up the inheritance chain.

## Requirements

- Windows PowerShell 5.1 (or PowerShell 7+).
- Network access to a Geo SCADA server's schema endpoint (default `https://localhost/schema/`).

To reach a self-signed `localhost` endpoint, the script disables TLS certificate validation
**for its own session only**.

## Usage

```powershell
# Default: crawl from CDBObject at https://localhost/schema/, write SchemaTree.html beside the script
.\GeoSCADA-Schema-Tree.ps1

# Accept the usage disclaimer without an interactive prompt (required in non-interactive sessions)
.\GeoSCADA-Schema-Tree.ps1 -AcceptDisclaimer

# Start from a different root class and/or write elsewhere
.\GeoSCADA-Schema-Tree.ps1 -RootClass CGroup -OutputPath C:\temp\groups.html

# Point at a remote server
.\GeoSCADA-Schema-Tree.ps1 -BaseUrl https://scada-host/schema/ -AcceptDisclaimer
```

Open the resulting `SchemaTree.html` in any modern browser. (See
[Example.SchemaTree.html](Example.SchemaTree.html) for a pre-generated sample.)

### Parameters

| Parameter           | Default                       | Description                                                        |
| ------------------- | ----------------------------- | ------------------------------------------------------------------ |
| `-RootClass`        | `CDBObject`                   | Class to start the crawl from (the root of the tree).              |
| `-BaseUrl`          | `https://localhost/schema/`   | Schema endpoint base URL.                                          |
| `-OutputPath`       | `SchemaTree.html` (by script) | Where to write the HTML. Falls back to the working directory if the script location can't be determined. |
| `-AcceptDisclaimer` | *(off)*                       | Accept the disclaimer non-interactively.                           |

## How it works

1. Fetch the root class page and parse its `<Subclass>` elements.
2. Recurse into each sub-class (each has its own schema page), caching pages and guarding
   against cycles.
3. For every class, capture its own members (`ConfigField`, `DataField`, `Aggregate`,
   `Method`/`Argument`, `AlarmCondition`/`SubCondition`) plus its friendly `name`, `category`,
   `schema` and `<Base>` pointer.
4. Render the tree server-side and embed each class's members as JSON for the client-side panel.

## Disclaimer

This script is provided **"AS IS"**, without warranty of any kind, express or implied. The author
accepts no liability for any damages arising from its use. It connects to the Geo SCADA schema web
endpoint to read schema metadata and writes an HTML file; to reach a self-signed localhost endpoint
it disables TLS certificate validation for the session. It is **NOT** certified for production SCADA
environments. Do **NOT** run it against a production or safety-critical system without first reviewing
the code and testing it on a representative non-production system. You run it at your own risk and are
responsible for compliance with your own change-control and security policies.

You are prompted to accept this disclaimer before the script runs (or pass `-AcceptDisclaimer`).

## License

Copyright (c) 2026 Adam Woodland.

Licensed under the **MIT License** &mdash; see the [LICENSE](LICENSE) file, or
<https://opensource.org/licenses/MIT>. This is free software, and you are welcome to
redistribute it under those conditions; it comes with **ABSOLUTELY NO WARRANTY**.
