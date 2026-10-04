"use strict";

// Custom markdownlint rule: table delimiter cells use exactly three dashes ("| --- |"),
// keeping alignment colons. MD060 only checks the padding around the dashes, so without
// this rule a padded "| ----- |" row passes and is never shortened.
//
// The rule only reads tokens and only reports edits; it touches no files and loads no
// modules, so running it from the user configuration is safe.

function* walk(tokens) {
  for (const token of tokens) {
    yield token;
    yield* walk(token.children);
  }
}

module.exports = {
  names: ["LCS001", "table-delimiter-dashes"],
  description: "Table delimiter cells use exactly three dashes",
  tags: ["table"],
  parser: "micromark",
  function: function LCS001(params, onError) {
    for (const token of walk(params.parsers.micromark.tokens)) {
      if (token.type !== "tableDelimiterRow") {
        continue;
      }
      const line = params.lines[token.startLine - 1];
      if (line === undefined) {
        continue;
      }
      const start = token.startColumn - 1;
      const row = line.slice(
        start,
        token.endLine === token.startLine ? token.endColumn - 1 : undefined,
      );
      for (const match of row.matchAll(/-+/g)) {
        if (match[0].length === 3) {
          continue;
        }
        const column = start + match.index + 1;
        onError({
          lineNumber: token.startLine,
          detail: `Expected: 3 dashes; Actual: ${match[0].length}`,
          range: [column, match[0].length],
          fixInfo: {
            lineNumber: token.startLine,
            editColumn: column,
            deleteCount: match[0].length,
            insertText: "---",
          },
        });
      }
    }
  },
};
