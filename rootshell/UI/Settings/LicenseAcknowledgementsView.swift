import SwiftUI

// MARK: - License Entry Model

struct LicenseEntry: Identifiable {
    let id = UUID()
    let name: String
    let licenseType: String
    let copyright: String
    let repositoryURL: String?
    let licenseText: String
}

// MARK: - License Row View

struct LicenseRow: View {
    let entry: LicenseEntry
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                // Copyright
                Text(entry.copyright)
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                // Repository link
                if let urlString = entry.repositoryURL,
                   let url = URL(string: urlString) {
                    Link(destination: url) {
                        HStack(spacing: 4) {
                            Image(systemName: "link")
                            Text(urlString.replacingOccurrences(of: "https://", with: ""))
                        }
                        .font(.caption)
                    }
                }

                // License text
                Text(entry.licenseText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(nil)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(sheetThemeColors?.rowBackground ?? Color(uiColor: .secondarySystemGroupedBackground))
                    .cornerRadius(6)
            }
            .padding(.vertical, 8)
        } label: {
            HStack {
                Text(entry.name)
                Spacer()
                Text(entry.licenseType)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Main View

struct LicenseAcknowledgementsView: View {
    var body: some View {
        List {
            Section {
                HStack(alignment: .center, spacing: 8) {
                    Image("AppIconImage")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 24)
                        .cornerRadius(6)

                    Text("Terminal emulator based on libghostty by Mitchell Hashimoto")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .themedRow()
            }

            Section("Core") {
                ForEach(coreLicenses) { entry in
                    LicenseRow(entry: entry)
                        .themedRow()
                }
            }

            Section("Fonts") {
                ForEach(fontLicenses) { entry in
                    LicenseRow(entry: entry)
                        .themedRow()
                }
            }

            Section("SSH & Networking") {
                ForEach(sshLicenses) { entry in
                    LicenseRow(entry: entry)
                        .themedRow()
                }
            }

            Section("Cloud & Kubernetes") {
                ForEach(cloudLicenses) { entry in
                    LicenseRow(entry: entry)
                        .themedRow()
                }
            }

            Section("Sounds") {
                ForEach(soundLicenses) { entry in
                    LicenseRow(entry: entry)
                        .themedRow()
                }
            }

            Section("Apple Open Source") {
                ForEach(appleLicenses) { entry in
                    LicenseRow(entry: entry)
                        .themedRow()
                }
            }
        }
        .themedList()
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - License Data

    private var coreLicenses: [LicenseEntry] {
        var entries = [
            LicenseEntry(
                name: "Ghostty / libghostty",
                licenseType: "MIT",
                copyright: "Copyright (c) 2024 Mitchell Hashimoto and Ghostty contributors",
                repositoryURL: "https://github.com/ghostty-org/ghostty",
                licenseText: mitLicenseText
            ),
        ]
        #if !targetEnvironment(macCatalyst)
        entries += [
            LicenseEntry(
                name: "ios_system",
                licenseType: "BSD 3-Clause",
                copyright: "Copyright (c) 2018 Nicolas Holzschuch",
                repositoryURL: "https://github.com/holzschu/ios_system",
                licenseText: bsd3ClauseLicenseText
            ),
            LicenseEntry(
                name: "jq",
                licenseType: "MIT",
                copyright: "Copyright (c) 2012 Stephen Dolan",
                repositoryURL: "https://github.com/jqlang/jq",
                licenseText: mitLicenseText
            ),
            LicenseEntry(
                name: "Vim",
                licenseType: "Vim License",
                copyright: "Copyright (c) 1991-2024 Bram Moolenaar and the Vim contributors",
                repositoryURL: "https://github.com/vim/vim",
                licenseText: vimLicenseText
            ),
            LicenseEntry(
                name: "curl",
                licenseType: "MIT",
                copyright: "Copyright (c) 1996-2026 Daniel Stenberg and many contributors",
                repositoryURL: "https://github.com/curl/curl",
                licenseText: mitLicenseText
            ),
            LicenseEntry(
                name: "Helix Editor",
                licenseType: "MPL-2.0",
                copyright: "Copyright (c) 2020 Blaž Hrastnik and Helix contributors",
                repositoryURL: "https://github.com/helix-editor/helix",
                licenseText: mpl2LicenseText
            ),
            LicenseEntry(
                name: "gitoxide",
                licenseType: "MIT / Apache 2.0",
                copyright: "Copyright (c) Sebastian Thiel and gitoxide contributors",
                repositoryURL: "https://github.com/GitoxideLabs/gitoxide",
                licenseText: mitApache2LicenseText
            ),
            LicenseEntry(
                name: "bat",
                licenseType: "MIT / Apache 2.0",
                copyright: "Copyright (c) 2018-2023 bat-developers",
                repositoryURL: "https://github.com/sharkdp/bat",
                licenseText: mitApache2LicenseText
            ),
            LicenseEntry(
                name: "ripgrep",
                licenseType: "Unlicense / MIT",
                copyright: "Copyright (c) 2015 Andrew Gallant",
                repositoryURL: "https://github.com/BurntSushi/ripgrep",
                licenseText: unlicenseMitLicenseText
            ),
            LicenseEntry(
                name: "libgit2",
                licenseType: "GPLv2 + Linking Exception",
                copyright: "Copyright (c) the libgit2 contributors",
                repositoryURL: "https://github.com/libgit2/libgit2",
                licenseText: gplv2LinkingExceptionText
            ),
            LicenseEntry(
                name: "libarchive",
                licenseType: "BSD-2-Clause",
                copyright: "Copyright (c) 2003-2024 Tim Kientzle and contributors",
                repositoryURL: "https://github.com/libarchive/libarchive",
                licenseText: bsd2ClauseLicenseText
            ),
        ]
        #endif
        #if STANDALONE
        entries.append(
            LicenseEntry(
                name: "Sparkle",
                licenseType: "MIT",
                copyright: "Copyright (c) 2006-2013 Andy Matuschak and Sparkle contributors",
                repositoryURL: "https://github.com/sparkle-project/Sparkle",
                licenseText: mitLicenseText
            )
        )
        #endif
        return entries
    }

    private var fontLicenses: [LicenseEntry] {
        [
            LicenseEntry(
                name: "0xProto",
                licenseType: "SIL OFL 1.1",
                copyright: "Copyright (c) 2024 0xType Project Authors",
                repositoryURL: "https://github.com/0xType/0xProto",
                licenseText: silOFLLicenseText
            ),
            LicenseEntry(
                name: "Fira Code",
                licenseType: "SIL OFL 1.1",
                copyright: "Copyright (c) 2014 The Fira Code Project Authors",
                repositoryURL: "https://github.com/tonsky/FiraCode",
                licenseText: silOFLLicenseText
            ),
            LicenseEntry(
                name: "Geist Mono",
                licenseType: "SIL OFL 1.1",
                copyright: "Copyright (c) 2023 Vercel",
                repositoryURL: "https://github.com/vercel/geist-font",
                licenseText: silOFLLicenseText
            ),
            LicenseEntry(
                name: "Nerd Fonts",
                licenseType: "MIT / SIL OFL 1.1",
                copyright: "Copyright (c) 2014 Ryan L McIntyre",
                repositoryURL: "https://github.com/ryanoasis/nerd-fonts",
                licenseText: mitLicenseText
            )
        ]
    }

    private var sshLicenses: [LicenseEntry] {
        [
            LicenseEntry(
                name: "Citadel",
                licenseType: "MIT",
                copyright: "Copyright (c) 2022 Orlandos",
                repositoryURL: "https://github.com/orlandos-nl/Citadel",
                licenseText: mitLicenseText
            ),
            LicenseEntry(
                name: "trzsz-ssh (tssh)",
                licenseType: "MIT",
                copyright: "Copyright (c) 2023 Lonny Wong",
                repositoryURL: "https://github.com/trzsz/trzsz-ssh",
                licenseText: mitLicenseText
            ),
            LicenseEntry(
                name: "CryptoSwift",
                licenseType: "zlib",
                copyright: "Copyright (c) 2014 Marcin Krzyżanowski",
                repositoryURL: "https://github.com/krzyzanowskim/CryptoSwift",
                licenseText: cryptoSwiftLicenseText
            ),
            LicenseEntry(
                name: "YubiKit",
                licenseType: "Apache 2.0",
                copyright: "Copyright (c) Yubico AB",
                repositoryURL: "https://github.com/kitknox/yubikit-swift-rootshell",
                licenseText: apache2LicenseText
            ),
            LicenseEntry(
                name: "IPinfo",
                licenseType: "CC BY-SA 4.0",
                copyright: "IP address data powered by IPinfo",
                repositoryURL: "https://ipinfo.io",
                licenseText: ccBySa4LicenseText
            ),
            LicenseEntry(
                name: "croc",
                licenseType: "MIT",
                copyright: "Copyright (c) 2017-2025 Zack Scholl",
                repositoryURL: "https://github.com/schollz/croc",
                licenseText: mitLicenseText
            )
        ]
    }

    private var cloudLicenses: [LicenseEntry] {
        var entries: [LicenseEntry] = [
            LicenseEntry(
                name: "SwiftkubeClient",
                licenseType: "Apache 2.0",
                copyright: "Copyright (c) 2020 Iskandar Abudiab",
                repositoryURL: "https://github.com/swiftkube/client",
                licenseText: apache2LicenseText
            ),
            LicenseEntry(
                name: "Yams",
                licenseType: "MIT",
                copyright: "Copyright (c) 2016 JP Simard",
                repositoryURL: "https://github.com/kitknox/Yams-rootshell",
                licenseText: mitLicenseText
            ),
        ]
        #if !CHINA_BUILD
        entries.append(LicenseEntry(
            name: "SwiftOpenAI",
            licenseType: "MIT",
            copyright: "Copyright (c) 2023 James Rochabrun",
            repositoryURL: "https://github.com/kitknox/SwiftOpenAI-rootshell",
            licenseText: mitLicenseText
        ))
        #endif
        return entries
    }

    private var soundLicenses: [LicenseEntry] {
        [
            LicenseEntry(
                name: "Sound Effects",
                licenseType: "CC0 1.0",
                copyright: "Includes sounds from Freesound.org (CC0 1.0 Public Domain) and original synthesized waveforms",
                repositoryURL: "https://freesound.org",
                licenseText: cc0LicenseText
            )
        ]
    }

    private var appleLicenses: [LicenseEntry] {
        [
            LicenseEntry(
                name: "Swift NIO",
                licenseType: "Apache 2.0",
                copyright: "Copyright (c) Apple Inc.",
                repositoryURL: "https://github.com/apple/swift-nio",
                licenseText: apache2LicenseText
            ),
            LicenseEntry(
                name: "Swift NIO SSH",
                licenseType: "Apache 2.0",
                copyright: "Copyright (c) Apple Inc.",
                repositoryURL: "https://github.com/apple/swift-nio-ssh",
                licenseText: apache2LicenseText
            ),
            LicenseEntry(
                name: "Swift Crypto",
                licenseType: "Apache 2.0",
                copyright: "Copyright (c) Apple Inc.",
                repositoryURL: "https://github.com/apple/swift-crypto",
                licenseText: apache2LicenseText
            )
        ]
    }

    // MARK: - License Texts

    private var mitLicenseText: String {
        """
        Permission is hereby granted, free of charge, to any person obtaining a copy \
        of this software and associated documentation files (the "Software"), to deal \
        in the Software without restriction, including without limitation the rights \
        to use, copy, modify, merge, publish, distribute, sublicense, and/or sell \
        copies of the Software, and to permit persons to whom the Software is \
        furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all \
        copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
        IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, \
        FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE \
        AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER \
        LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, \
        OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE \
        SOFTWARE.
        """
    }

    private var bsd2ClauseLicenseText: String {
        """
        Redistribution and use in source and binary forms, with or without \
        modification, are permitted provided that the following conditions are met:

        1. Redistributions of source code must retain the above copyright notice, \
        this list of conditions and the following disclaimer.

        2. Redistributions in binary form must reproduce the above copyright notice, \
        this list of conditions and the following disclaimer in the documentation \
        and/or other materials provided with the distribution.

        THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" \
        AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE \
        IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE \
        DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE \
        FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL \
        DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR \
        SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER \
        CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, \
        OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE \
        OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
        """
    }

    private var bsd3ClauseLicenseText: String {
        """
        Redistribution and use in source and binary forms, with or without \
        modification, are permitted provided that the following conditions are met:

        1. Redistributions of source code must retain the above copyright notice, \
        this list of conditions and the following disclaimer.

        2. Redistributions in binary form must reproduce the above copyright notice, \
        this list of conditions and the following disclaimer in the documentation \
        and/or other materials provided with the distribution.

        3. Neither the name of the copyright holder nor the names of its contributors \
        may be used to endorse or promote products derived from this software without \
        specific prior written permission.

        THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" \
        AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE \
        IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE \
        DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE \
        FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL \
        DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR \
        SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER \
        CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, \
        OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE \
        OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
        """
    }

    private var silOFLLicenseText: String {
        """
        This Font Software is licensed under the SIL Open Font License, Version 1.1.

        Permission is hereby granted, free of charge, to any person obtaining a copy \
        of the Font Software, to use, study, copy, merge, embed, modify, redistribute, \
        and sell modified and unmodified copies of the Font Software, subject to the \
        following conditions:

        1) Neither the Font Software nor any of its individual components, in Original \
        or Modified Versions, may be sold by itself.

        2) Original or Modified Versions of the Font Software may be bundled, \
        redistributed and/or sold with any software, provided that each copy contains \
        the above copyright notice and this license.

        3) No Modified Version of the Font Software may use the Reserved Font Name(s) \
        unless explicit written permission is granted by the corresponding Copyright Holder.

        4) The name(s) of the Copyright Holder(s) or the Author(s) of the Font Software \
        shall not be used to promote, endorse or advertise any Modified Version, except \
        to acknowledge the contribution(s) of the Copyright Holder(s) and the Author(s) \
        or with their explicit written permission.

        5) The Font Software, modified or unmodified, in part or in whole, must be \
        distributed entirely under this license, and must not be distributed under any \
        other license.

        THE FONT SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
        IMPLIED, INCLUDING BUT NOT LIMITED TO ANY WARRANTIES OF MERCHANTABILITY, FITNESS \
        FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF COPYRIGHT, PATENT, TRADEMARK, \
        OR OTHER RIGHT. IN NO EVENT SHALL THE COPYRIGHT HOLDER BE LIABLE FOR ANY CLAIM, \
        DAMAGES OR OTHER LIABILITY, INCLUDING ANY GENERAL, SPECIAL, INDIRECT, INCIDENTAL, \
        OR CONSEQUENTIAL DAMAGES, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, \
        ARISING FROM, OUT OF THE USE OR INABILITY TO USE THE FONT SOFTWARE OR FROM OTHER \
        DEALINGS IN THE FONT SOFTWARE.
        """
    }

    private var vimLicenseText: String {
        """
        I)  There are no restrictions on distributing unmodified copies of Vim \
        except that they must include this license text. You can also distribute \
        unmodified parts of Vim, likewise unrestricted except that they must include \
        this license text. You are also allowed to include executables that you made \
        from the unmodified Vim sources, plus your own usage examples and Vim scripts.

        II) It is allowed to distribute a modified (or extended) version of Vim, \
        including executables and/or source code, when the following four conditions \
        are met:
        1) This license text must be included unmodified.
        2) The modified Vim must be distributed in one of the following five ways:
           a) If you make changes to Vim yourself, you must clearly describe in the \
        distribution how to contact you. When the maintainer asks you (in any way) \
        for a copy of the modified Vim you distributed, you must make your changes, \
        including source code, available to the maintainer without fee.
           b) If you have received a modified Vim that was distributed as mentioned \
        under a) you are allowed to further distribute it unmodified, as mentioned at I).
           c) Provide all the changes, including source code, with every copy of the \
        modified Vim you distribute. This may be done in the form of a context diff.
           d) When you have a modified Vim which includes changes as mentioned under c), \
        you can distribute it without the source code for the changes if the license \
        that applies to the changes permits you to distribute the changes to the Vim \
        maintainer without fee or restriction, and you keep the changes for at least \
        three years after last distributing the corresponding modified Vim.
           e) When the GNU General Public License (GPL) applies to the changes, you \
        can distribute the modified Vim under the GNU GPL version 2 or any later version.
        3) A message must be added, at least in the output of the ":version" command \
        and in the intro screen, such that the user of the modified Vim is able to see \
        that it was modified.
        4) The contact information as required under 2)a) and 2)d) must not be removed \
        or changed, except that the person himself can make corrections.

        III) If you distribute a modified version of Vim, you are encouraged to use the \
        Vim license for your changes and make them available to the maintainer, \
        including the source code. The e-mail address to be used is <maintainer@vim.org>

        IV) It is not allowed to remove this license from the distribution of the Vim \
        sources, parts of it or from a modified version. You may use this license for \
        previous Vim releases instead of the license that they came with, at your option.
        """
    }

    private var cryptoSwiftLicenseText: String {
        """
        This software is provided 'as-is', without any express or implied warranty. \
        In no event will the authors be held liable for any damages arising from the \
        use of this software.

        Permission is granted to anyone to use this software for any purpose, including \
        commercial applications, and to alter it and redistribute it freely, subject to \
        the following restrictions:

        1) The origin of this software must not be misrepresented; you must not claim \
        that you wrote the original software. If you use this software in a product, an \
        acknowledgment in the product documentation is required.

        2) Altered source versions must be plainly marked as such, and must not be \
        misrepresented as being the original software.

        3) This notice may not be removed or altered from any source or binary distribution.

        4) Redistributions of any form whatsoever must retain the following acknowledgment: \
        'This product includes software developed by Marcin Krzyzanowski.'
        """
    }

    private var mpl2LicenseText: String {
        """
        This Source Code Form is subject to the terms of the Mozilla Public \
        License, v. 2.0. If a copy of the MPL was not distributed with this \
        file, You can obtain one at https://mozilla.org/MPL/2.0/.
        """
    }

    private var mitApache2LicenseText: String {
        """
        Licensed under either of:

        • Apache License, Version 2.0 (http://www.apache.org/licenses/LICENSE-2.0)
        • MIT License (http://opensource.org/licenses/MIT)

        at your option.

        ---

        \(mitLicenseText)
        """
    }

    private var unlicenseMitLicenseText: String {
        """
        Licensed under either of:

        \u{2022} The Unlicense (http://unlicense.org/)
        \u{2022} MIT License (http://opensource.org/licenses/MIT)

        at your option.

        ---

        \(mitLicenseText)
        """
    }

    private var cc0LicenseText: String {
        """
        CC0 1.0 Universal (CC0 1.0) Public Domain Dedication

        The person who associated a work with this deed has dedicated the work \
        to the public domain by waiving all of his or her rights to the work \
        worldwide under copyright law, including all related and neighboring \
        rights, to the extent allowed by law.

        You can copy, modify, distribute and perform the work, even for \
        commercial purposes, all without asking permission.
        """
    }

    private var apache2LicenseText: String {
        """
        Licensed under the Apache License, Version 2.0 (the "License"); \
        you may not use this file except in compliance with the License. \
        You may obtain a copy of the License at

            http://www.apache.org/licenses/LICENSE-2.0

        Unless required by applicable law or agreed to in writing, software \
        distributed under the License is distributed on an "AS IS" BASIS, \
        WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. \
        See the License for the specific language governing permissions and \
        limitations under the License.
        """
    }

    private var gplv2LinkingExceptionText: String {
        """
        In addition to the permissions in the GNU General Public License, \
        the authors give you unlimited permission to link the compiled \
        version of this library into combinations with other programs, \
        and to distribute those combinations without any restriction \
        coming from the use of this file. (The General Public License \
        restrictions do apply in other respects; for example, they cover \
        modification of the file, and distribution when not linked into \
        a combined executable.)

        This library is free software; you can redistribute it and/or \
        modify it under the terms of the GNU General Public License as \
        published by the Free Software Foundation; version 2 of the License.

        This library is distributed in the hope that it will be useful, \
        but WITHOUT ANY WARRANTY; without even the implied warranty of \
        MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU \
        General Public License for more details.

        You should have received a copy of the GNU General Public License \
        along with this library; if not, see <https://www.gnu.org/licenses/>.
        """
    }

    private var ccBySa4LicenseText: String {
        """
        This work is licensed under the Creative Commons Attribution-ShareAlike \
        4.0 International License. To view a copy of this license, visit \
        http://creativecommons.org/licenses/by-sa/4.0/ or send a letter to \
        Creative Commons, PO Box 1866, Mountain View, CA 94042, USA.
        """
    }
}

#Preview {
    NavigationView {
        LicenseAcknowledgementsView()
    }
}
