# Third-party notices

jev vendors the following third-party source. Each entry records the exact
upstream revision and content hash, so re-vendoring is a clean diff and a
careless copy is caught by a launch assertion rather than by a user.

---

## `Sources/JevWeb/Resources/snapshot.js`

Vendored **byte-identical** from jev-ultrafast. Do not edit in place: to update,
re-copy from upstream and update the revision and hash below, then re-run the
self-tests — `WebSelfTest` asserts the safety-critical exclusion is still present.

- Upstream: https://github.com/browser-use/jev-ultrafast
- Path: `jev_ultrafast/snapshot.js`
- Revision: `1231850a0bf1a0c0341fe408ef1668dbbfdfac46`
- SHA-256: `e50473501c8fb8e70f3b21866d987393e3f2315c639d638bd477d170e81ed78d`

Why it is vendored rather than reimplemented: it is the transport-free half of
jev-ultrafast. It runs in the page and needs no CDP, so it carries over to a
Swift host unchanged, and reimplementing it would mean re-deriving its accessible
-name algorithm and its visibility and occlusion rules — the parts most likely to
be got subtly wrong.

One behaviour in it is safety-critical and is asserted at launch:

```js
const safe = e => !['password','file','hidden'].includes(e.type);
```

Password, file and hidden inputs are excluded from the action table before any
page content reaches a model. jev's requirement never to type into a password
field is therefore structural, not a rule applied afterwards.

### Licence

MIT License

Copyright (c) 2026 Browser Use

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
