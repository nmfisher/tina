// This file is broken ON PURPOSE. It probes parser robustness: tina's
// index must not crash or lose the rest of the workspace when one file
// fails to parse. Do not fix the syntax errors. Do not delete this file.
//
// Expected parse failures below:
//   - unterminated string literal
//   - `class` with no name
//   - a stray closing brace

const brokenProbeVersion = '0.1.0; // oops — unterminated

class {
}

}
