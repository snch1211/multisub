# Third-Party Notices

MultiSub is distributed under the MIT License (see `LICENSE`). It bundles or
builds upon the third-party components listed below. Each remains under its own
license; the relevant notices are reproduced or referenced here.

---

## Swift Package dependencies

Versions reflect `MultiSub.xcodeproj/.../Package.resolved` at the time of
release. The full license text for each package lives in that package's own
repository (linked below).

### MIT License

| Package | Version | Copyright | Source |
|---|---|---|---|
| mlx-swift | 0.31.6 | © 2023 ml-explore | https://github.com/ml-explore/mlx-swift |
| mlx-swift-lm | (pinned revision) | © 2024 ml-explore | https://github.com/ml-explore/mlx-swift-lm |
| yyjson | 0.12.0 | © 2020 YaoYuan (ibireme) | https://github.com/ibireme/yyjson |
| EventSource | 1.4.1 | © 2025 Mattt | https://github.com/mattt/EventSource |

All four are provided under the MIT License, the full text of which is
reproduced in the **MIT License text** section below.

### Apache License 2.0

| Package | Version | Copyright | Source |
|---|---|---|---|
| swift-huggingface | 0.9.0 | © Hugging Face SAS | https://github.com/huggingface/swift-huggingface |
| swift-transformers | 1.3.3 | © Hugging Face SAS | https://github.com/huggingface/swift-transformers |
| swift-jinja | 2.3.6 | © Hugging Face SAS | https://github.com/huggingface/swift-jinja |
| swift-argument-parser | 1.8.2 | © Apple Inc. and the Swift project authors | https://github.com/apple/swift-argument-parser |
| swift-asn1 | 1.7.1 | © Apple Inc. and the Swift project authors | https://github.com/apple/swift-asn1 |
| swift-atomics | 1.3.1 | © Apple Inc. and the Swift project authors | https://github.com/apple/swift-atomics |
| swift-collections | 1.6.0 | © Apple Inc. and the Swift project authors | https://github.com/apple/swift-collections |
| swift-crypto | 4.5.0 | © Apple Inc. and the Swift project authors | https://github.com/apple/swift-crypto |
| swift-nio | 2.101.2 | © Apple Inc. and the Swift project authors | https://github.com/apple/swift-nio |
| swift-numerics | 1.1.1 | © Apple Inc. and the Swift project authors | https://github.com/apple/swift-numerics |
| swift-syntax | 603.0.2 | © Apple Inc. and the Swift project authors | https://github.com/swiftlang/swift-syntax |
| swift-system | 1.7.2 | © Apple Inc. and the Swift project authors | https://github.com/apple/swift-system |

These components are licensed under the Apache License, Version 2.0. You may
obtain a copy of the License at:

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed
under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
CONDITIONS OF ANY KIND, either express or implied. See the License for the
specific language governing permissions and limitations under the License.

The Apple / Swift.org packages above additionally carry the **Swift.org Runtime
Library Exception** to the Apache 2.0 License (permitting redistribution of
binaries that embed portions of the software without the attribution otherwise
required by Sections 4(a), 4(b) and 4(d) of the License). See each package's
`LICENSE.txt` for the exact text.

---

## MIT License text

```
MIT License

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
```

---

## CEFR word-list data

The bundled English → CEFR level table (`MultiSub/MultiSub/Resources/
cefr-wordlist-en.txt`) is derived from two published datasets. Its file header
carries the same citation and must be kept intact.

- **A1–B2 levels** — *The CEFR-J Wordlist* version 1.5, compiled by Yukio Tono,
  Tokyo University of Foreign Studies (TUFS).
  Source: https://github.com/openlanguageprofiles/olp-en-cefrj
  License: the dataset may be used for research and commercial purposes free of
  charge, **provided that it is cited properly**. Copyright belongs to Tono
  Laboratory at TUFS. This notice, together with the file header, is that
  citation.

- **C1–C2 levels** — *Octanove Vocabulary Profile for C1/C2 levels* version 1.0,
  by Octanove Labs (http://www.octanove.com/), from the same repository.
  License: **Creative Commons Attribution-ShareAlike 4.0 International**
  (CC BY-SA 4.0), https://creativecommons.org/licenses/by-sa/4.0/.

**Scope of the ShareAlike obligation.** CC BY-SA 4.0's share-alike term applies
to *that data file and adaptations of it* — i.e. the C1–C2 portion of
`cefr-wordlist-en.txt`. Keeping the attribution in the file header satisfies the
license. It does **not** relicense the rest of MultiSub: the application source
code remains under the MIT License. The CC BY-SA obligation does not propagate
to code that merely reads the data at run time.

---

## Local translation model

MultiSub runs a Gemma-family model locally via MLX. The model weights are
**not** bundled with this software; they are downloaded on first use from
Hugging Face under the model publisher's own license terms, which the user
accepts on the model's Hugging Face page. Review that license before use.

---

## Trademark and affiliation notice

MultiSub is an unofficial, community-built project. It is **not affiliated with,
endorsed, sponsored by, or in any way officially connected to Netflix, Inc.**
"Netflix" and related marks are trademarks of their respective owners and are
used here only for descriptive, nominative purposes. No Netflix logo or branding
is used, and no official relationship is implied.
