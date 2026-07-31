# Diagram sources

Each `.mmd` here is the source for the `.svg` beside it. Edit the `.mmd`,
re-render, and commit both.

```bash
npx -y @mermaid-js/mermaid-cli -i docs/diagrams/release-flow.mmd \
  -o docs/diagrams/release-flow.svg -c docs/diagrams/mermaid-config.json -b white
```

Colour carries meaning, so keep it consistent across diagrams: **blue for
things that run code** (environments), **sand for things that store it**
(repositories). Both are defined as `classDef env` / `classDef repo` in the
source rather than per-node styles, so a new box joins a category rather
than picking its own colour.

Two things about `mermaid-config.json` that are not incidental:

- **`htmlLabels: false`.** Mermaid renders labels as `<foreignObject>` by
  default, and GitHub shows an embedded SVG containing `foreignObject` as a
  blank box. Without this the diagram renders perfectly in a browser and is
  invisible in the docs. It costs `<b>` markup in labels, which stops being
  interpreted and would appear literally.
- **The `layout: elk` line in the `.mmd` itself.** ELK routes orthogonally
  and places labels without collisions, which dagre could not manage for
  this graph. It needs `@mermaid-js/layout-elk`, which mermaid-cli bundles
  but GitHub's own mermaid does not — which is the other reason these are
  pre-rendered and embedded rather than written inline as ```` ```mermaid ````
  blocks.

Diagrams that *are* simple enough for dagre stay inline in the docs, where
GitHub renders them from source — see the sequence diagram in
[3.3](../3.3-testing-ci-and-release.md). Inline is preferable when it works:
no rendering step, and the source is the thing you read.
