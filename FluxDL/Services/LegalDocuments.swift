import Foundation

// MARK: - Models

/// A single heading + body block inside a legal document.
public struct LegalSection: Identifiable {
    public let id = UUID()
    public let heading: String
    public let body: String

    public init(heading: String, body: String) {
        self.heading = heading
        self.body = body
    }
}

/// A complete legal document rendered by the native legal pages.
public struct LegalDocument: Identifiable {
    public let id: String
    public let title: String
    public let effectiveDate: String
    public let sections: [LegalSection]

    public init(id: String, title: String, effectiveDate: String, sections: [LegalSection]) {
        self.id = id
        self.title = title
        self.effectiveDate = effectiveDate
        self.sections = sections
    }
}

/// A third-party component distributed inside FluxDL and its license text.
public struct LicenseEntry: Identifiable {
    public let id: String
    public let name: String
    /// Short one-liner shown in the Licenses list (license name + copyright).
    public let summary: String
    /// The full license text shown on the detail page.
    public let licenseText: String

    public init(id: String, name: String, summary: String, licenseText: String) {
        self.id = id
        self.name = name
        self.summary = summary
        self.licenseText = licenseText
    }
}

// MARK: - Centralized Legal Source

/// Single source of truth for all in-app legal documents and license texts.
/// These pages are rendered natively inside Settings; nothing here is loaded
/// from the network, so the documents keep working offline.
public enum LegalDocuments {

    public static let effectiveDate = "August 14, 2026"

    public static let appName = "FluxDL"
    public static let developerName = "RAKIB"
    /// Real, reachable contact point: the official project repository.
    public static let contactURLString = "https://github.com/rakibshorkar2/FluxDL"

    // MARK: - Privacy Policy

    public static let privacyPolicy = LegalDocument(
        id: "privacy",
        title: "Privacy Policy",
        effectiveDate: effectiveDate,
        sections: [
            LegalSection(
                heading: "1. Overview",
                body: """
                FluxDL is a download manager for iOS developed by \(developerName). This Privacy Policy explains what information FluxDL handles, what is stored locally on your device, and what communications leave your device. FluxDL has no accounts, no advertising, no analytics SDKs, and no cloud infrastructure operated by the developer. Everything you do with FluxDL is initiated by you on your device.
                """
            ),
            LegalSection(
                heading: "2. Information We Collect",
                body: """
                FluxDL does not collect personal information. The developer does not operate servers that receive telemetry, analytics, or usage data from the app. FluxDL does not create an account, does not require registration, and does not send your personal data anywhere unless you explicitly perform an action described in this policy (such as starting a download, opening a website, or enabling AI interpretation with your own API key).
                """
            ),
            LegalSection(
                heading: "3. Information Stored Locally",
                body: """
                FluxDL stores data locally on your device using iOS system storage (UserDefaults and app containers). This includes your settings, the selected theme, download directories you have chosen, bookmarks, download history, and similar state needed to make the app work. Secrets, such as a Gemini API key you provide for AI interpretation, are stored in the iOS Keychain, which is encrypted by the system. Your files and downloads remain in the storage locations you choose on your device.
                """
            ),
            LegalSection(
                heading: "4. Network Communications",
                body: """
                FluxDL only communicates over the network when you perform a task that requires it. Examples: fetching a file or directory listing from a server you specify, browsing a website you open, contacting torrent trackers and peers for a torrent you start, checking for app updates, or sending a search query to an AI service you have enabled. Every network operation is initiated by you, uses your own network connection, and is performed for the purpose you requested.
                """
            ),
            LegalSection(
                heading: "5. Downloads",
                body: """
                When you download a file, FluxDL connects to the address you provided (directly, or through a proxy you configured) and saves the file to the location you choose. File names, URLs, and download history are stored only on your device. The developer cannot see, receive, or access your downloads. You are responsible for downloading only content you are authorized to access and store.
                """
            ),
            LegalSection(
                heading: "6. Browser",
                body: """
                FluxDL includes a web browser based on the system WebKit engine. Pages you visit are fetched directly by your device, subject to the privacy and data practices of those websites. FluxDL does not read, log, or transmit your browsing activity. Website data such as cookies may be stored locally by the system engine and can be cleared at any time.
                """
            ),
            LegalSection(
                heading: "7. Directory Mode",
                body: """
                Directory Mode lets you browse file listings on servers you specify and download files from them. The URLs and any authentication details you enter are used only to reach those servers and are stored locally. When you enable AI interpretation, FluxDL sends your search text to the Gemini API service using your own API key (see "Third-Party Services").
                """
            ),
            LegalSection(
                heading: "8. Proxy Features",
                body: """
                FluxDL lets you configure proxy servers (such as SOCKS5 or HTTP proxies) and route connections through them. Proxy settings you enter are stored locally on your device. When a proxy is enabled, connections pass through the proxy you configured; the proxy operator may see traffic according to that operator's own policies. FluxDL does not provide or operate any proxy service itself.
                """
            ),
            LegalSection(
                heading: "9. Torrent Features",
                body: """
                FluxDL's torrent support is powered by the libtorrent engine, which is built into the app. When you add a torrent, the engine contacts the trackers and peers associated with that torrent using the protocol's standard behavior. Your IP address is visible to trackers and peers you connect to, as is inherent in the BitTorrent protocol. Magnet links and torrent files you add are stored locally. You are responsible for complying with the laws of your jurisdiction and for using torrents only with content you are authorized to share.
                """
            ),
            LegalSection(
                heading: "10. Third-Party Services",
                body: """
                FluxDL can communicate with the following third-party services, all used only on your initiative:

                • GitHub: used only to check whether a new FluxDL version exists and to open the official project page. When you check for updates, the app contacts the public GitHub API.
                • Google Gemini (optional): if you enable AI interpretation in Directory Mode, FluxDL sends your search text to the Gemini API using your own API key. The key is stored in the iOS Keychain on your device and is never shared with the developer. Without a key, AI interpretation is unavailable.
                • Torrent trackers and peers, web servers, and other endpoints: only as required by the downloads and browsing you initiate.

                Each service applies its own privacy policy to the data it processes. FluxDL is not affiliated with these services.
                """
            ),
            LegalSection(
                heading: "11. Data Retention and Deletion",
                body: """
                Data stored locally stays on your device until you remove it. You can delete download history, bookmarks, and individual downloads at any time inside the app. Uninstalling FluxDL removes its app-container data; Keychain items may remain until removed through the app or iOS. FluxDL does not retain any data on the developer's servers because none exists.
                """
            ),
            LegalSection(
                heading: "12. Children's Privacy",
                body: """
                FluxDL is not directed to children and does not knowingly collect any information from children. Because the app does not collect personal information at all, there is no personal data to gather from any user, regardless of age.
                """
            ),
            LegalSection(
                heading: "13. Changes to This Policy",
                body: """
                This Privacy Policy may be updated to reflect changes in the app's behavior or legal requirements. The "Effective" date at the top of this page indicates the latest revision. Continued use of FluxDL after changes take effect constitutes acceptance of the updated policy.
                """
            ),
            LegalSection(
                heading: "14. Contact",
                body: """
                This policy is maintained by the developer. For questions or concerns about this policy, open an issue in the official repository at \(contactURLString). Do not include sensitive personal information in public issue reports.
                """
            )
        ]
    )

    // MARK: - Terms of Service

    public static let termsOfService = LegalDocument(
        id: "terms",
        title: "Terms of Service",
        effectiveDate: effectiveDate,
        sections: [
            LegalSection(
                heading: "1. Acceptance of These Terms",
                body: """
                By downloading, installing, or using \(appName) you agree to these Terms of Service. If you do not agree, do not install or use the app. These terms are an agreement between you and \(developerName), the developer of \(appName).
                """
            ),
            LegalSection(
                heading: "2. License to Use",
                body: """
                You are granted a limited, personal, non-exclusive, non-transferable, revocable license to install and use \(appName) on iOS devices you own or control, solely for your personal use. This license does not grant you any rights to the app's source code, trademarks, or other intellectual property, except as provided by applicable open-source licenses for components included in the app.
                """
            ),
            LegalSection(
                heading: "3. User Responsibilities",
                body: """
                You are solely responsible for how you use \(appName), including the content you download, browse, or share. You must have the legal right to access, download, store, and use any content you process with the app, and you must comply with the laws of your jurisdiction and with the policies of any network, server, tracker, or service you use.
                """
            ),
            LegalSection(
                heading: "4. Prohibited Conduct",
                body: """
                You agree not to: use \(appName) to infringe the intellectual property or other rights of others; distribute malicious or unlawful content; interfere with or disrupt any server, network, or service; attempt to gain unauthorized access to systems; or use the app to circumvent technical or legal protections. Downloading content you are not authorized to download may violate the law.
                """
            ),
            LegalSection(
                heading: "5. Content and Download Disclaimer",
                body: """
                \(appName) provides tools for downloading and browsing content. The app does not host, publish, endorse, or verify any content you download or access. All content originates from third-party servers, websites, and peer-to-peer networks. The developer is not responsible for the accuracy, legality, availability, or quality of any content downloaded with the app. You alone choose what to download and bear responsibility for your choices.
                """
            ),
            LegalSection(
                heading: "6. Intellectual Property",
                body: """
                \(appName), its name, and branding are the property of the developer. Third-party components included in the app are licensed under their respective open-source licenses, which are listed in Settings → About → Licenses. Your use of those components is governed by their own license terms.
                """
            ),
            LegalSection(
                heading: "7. Third-Party Services",
                body: """
                \(appName) may connect to third-party services at your direction, including GitHub, the Google Gemini API, and any web servers, proxies, trackers, or peers you configure. These services are independent of the developer and have their own terms and privacy policies. The developer is not responsible for the operation or content of third-party services.
                """
            ),
            LegalSection(
                heading: "8. Disclaimer of Warranties",
                body: """
                \(appName) is provided "as is" and "as available" without warranties of any kind, express or implied, including but not limited to implied warranties of merchantability, fitness for a particular purpose, and non-infringement. The developer does not warrant that the app will be uninterrupted, error-free, or secure. You use the app at your own risk.
                """
            ),
            LegalSection(
                heading: "9. Limitation of Liability",
                body: """
                To the maximum extent permitted by law, \(developerName) shall not be liable for any indirect, incidental, special, consequential, or punitive damages, or any loss of data, downloads, or profits, arising out of or related to your use of \(appName), even if advised of the possibility of such damages. In no event shall the developer's total liability exceed the amount you paid for the app, if any.
                """
            ),
            LegalSection(
                heading: "10. Indemnification",
                body: """
                To the maximum extent permitted by law, you agree to indemnify and hold harmless the developer from any claims, damages, liabilities, and expenses arising out of your use of \(appName) or your violation of these Terms, including claims related to content you downloaded or shared.
                """
            ),
            LegalSection(
                heading: "11. Termination",
                body: """
                Your license to use \(appName) terminates automatically if you violate these Terms. You may terminate your license at any time by uninstalling the app. Upon termination, your local data may remain on your device until you delete it; the developer has no server-side data to delete.
                """
            ),
            LegalSection(
                heading: "12. Changes to These Terms",
                body: """
                These Terms may be revised from time to time. The "Effective" date at the top of this page indicates the latest revision. Your continued use of \(appName) after changes take effect constitutes acceptance of the revised Terms.
                """
            ),
            LegalSection(
                heading: "13. Governing Law",
                body: """
                These Terms are governed by the laws of the jurisdiction in which you reside, excluding conflict-of-law rules, except where mandatory consumer-protection law provides otherwise. You are responsible for complying with all applicable local laws.
                """
            ),
            LegalSection(
                heading: "14. Contact",
                body: """
                For questions about these Terms, open an issue in the official repository at \(contactURLString). Do not include sensitive personal information in public issue reports.
                """
            )
        ]
    )

    // MARK: - Licenses

    /// Third-party components actually distributed inside the FluxDL app.
    /// Entries mirror what is bundled in the release build: the libtorrent
    /// engine, its Swift bindings, the Yams YAML parser, and the statically
    /// linked Boost and OpenSSL libraries.
    public static let licenseEntries: [LicenseEntry] = [
        LicenseEntry(
            id: "libtorrent",
            name: "libtorrent",
            summary: "BSD-3-Clause · Copyright (c) 2003-2020 Arvid Norberg",
            licenseText: """
            Copyright (c) 2003-2020, Arvid Norberg
            All rights reserved.

            Redistribution and use in source and binary forms, with or without
            modification, are permitted provided that the following conditions
            are met:

                * Redistributions of source code must retain the above copyright
                  notice, this list of conditions and the following disclaimer.
                * Redistributions in binary form must reproduce the above copyright
                  notice, this list of conditions and the following disclaimer in
                  the documentation and/or other materials provided with the distribution.
                * Neither the name of the author nor the names of its
                  contributors may be used to endorse or promote products derived
                  from this software without specific prior written permission.

            THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
            AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
            IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
            ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
            LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
            CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
            SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
            INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
            CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
            ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
            POSSIBILITY OF SUCH DAMAGE.

            ------------------------------------------------------------------------------

            puff.c
            Copyright (C) 2002, 2003 Mark Adler
            For conditions of distribution and use, see copyright notice in puff.h
            version 1.7, 3 Mar 2003

            ------------------------------------------------------------------------------

            bindings/python/src/

            Boost Software License - Version 1.0 - August 17th, 2003

            ------------------------------------------------------------------------------

            ed25519 implementation based on:

            Copyright (c) 2015 Orson Peters <orsonpeters@gmail.com>

            This software is provided 'as-is', without any express or implied warranty. In no event will the
            authors be held liable for any damages arising from the use of this software.

            Permission is granted to anyone to use this software for any purpose, including commercial
            applications, and to alter it and redistribute it freely, subject to the following restrictions:

            1. The origin of this software must not be misrepresented; you must not claim that you wrote the
               original software. If you use this software in a product, an acknowledgment in the product
               documentation would be appreciated but is not required.

            2. Altered source versions must be plainly marked as such, and must not be misrepresented as
               being the original software.

            3. This notice may not be removed or altered from any source distribution.

            ------------------------------------------------------------------------------

            src/sha1.cpp include/libtorrent/aux_/sha1.hpp

            SHA-1 in C
            By Steve Reid <sreid@sea-to-sky.net>
            100% Public Domain

            ------------------------------------------------------------------------------

            include/libtorrent/_aux/route.h

             * Copyright (c) 2000-2008 Apple Inc. All rights reserved.
             *
             * @APPLE_OSREFERENCE_LICENSE_HEADER_START@
             *
             * This file contains Original Code and/or Modifications of Original Code
             * as defined in and that are subject to the Apple Public Source License
             * Version 2.0 (the 'License'). You may not use this file except in
             * compliance with the License. The rights granted to you under the License
             * may not be used to create, or enable the creation or redistribution of,
             * unlawful or unlicensed copies of an Apple operating system, or to
             * circumvent, violate, or enable the circumvention or violation of, any
             * terms of an Apple operating system software license agreement.
             *
             * Please obtain a copy of the License at
             * http://www.opensource.apple.com/apsl/ and read it before using this file.
             *
             * The Original Code and all software distributed under the License are
             * distributed on an 'AS IS' basis, WITHOUT WARRANTY OF ANY KIND, EITHER
             * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
             * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
             * FITNESS FOR A PARTICULAR PURPOSE, QUIET ENJOYMENT OR NON-INFRINGEMENT.
             * Please see the License for the specific language governing rights and
             * limitations under the License.
             *
             * Copyright (c) 1980, 1986, 1993
             * The Regents of the University of California.  All rights reserved.
             *
             * Redistribution and use in source and binary forms, with or without
             * modification, are permitted provided that the following conditions
             * are met:
             * 1. Redistributions of source code must retain the above copyright
             *    notice, this list of conditions and the following disclaimer.
             * 2. Redistributions in binary form must reproduce the above copyright
             *    notice, this list of conditions and the following disclaimer in the
             *    documentation and/or other materials provided with the distribution.
             * 3. All advertising materials mentioning features or use of this software
             *    must display the following acknowledgement:
             *  This product includes software developed by the University of
             *  California, Berkeley and its contributors.
             * 4. Neither the name of the University nor the names of its contributors
             *    may be used to endorse or promote products derived from this software
             *    without specific prior written permission.
             *
             * THIS SOFTWARE IS PROVIDED BY THE REGENTS AND CONTRIBUTORS ``AS IS'' AND
             * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
             * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
             * ARE DISCLAIMED.  IN NO EVENT SHALL THE REGENTS OR CONTRIBUTORS BE LIABLE
             * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
             * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
             * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
             * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
             * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
             * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
             * SUCH DAMAGE.

             ------------------------------------------------------------------------------

            src/sha256.cpp

            SHA-256. Adapted from LibTomCrypt. This code is Public Domain
            """
        ),
        LicenseEntry(
            id: "libtorrent-swift",
            name: "LibTorrent-Swift",
            summary: "MIT · Copyright (c) 2015-2020 Norio Nomura",
            licenseText: """
            The MIT License (MIT)

            Copyright (c) 2015-2020 Norio Nomura

            Permission is hereby granted, free of charge, to any person obtaining a copy
            of this software and associated documentation files (the "Software"), to deal
            in the Software without restriction, including without limitation the rights
            to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
            copies of the Software, and to permit persons to whom the Software is
            furnished to do so, subject to the following conditions:

            The above copyright notice and this permission notice shall be included in
            all copies or substantial portions of the Software.

            THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
            IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
            FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
            AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
            LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
            OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
            THE SOFTWARE.

            Note: no license file ships inside the vendored copy of LibTorrent-Swift;
            the attribution above follows the upstream LibTorrent-Swift repository.
            """
        ),
        LicenseEntry(
            id: "yams",
            name: "Yams",
            summary: "MIT · Copyright (c) 2016 JP Simard",
            licenseText: """
            The MIT License (MIT)

            Copyright (c) 2016 JP Simard.

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
            """
        ),
        LicenseEntry(
            id: "boost",
            name: "Boost",
            summary: "Boost Software License 1.0 · build-time dependency of libtorrent, linked into the app",
            licenseText: """
            Boost Software License - Version 1.0 - August 17th, 2003

            Permission is hereby granted, free of charge, to any person or organization
            obtaining a copy of the software and accompanying documentation covered by
            this license (the "Software") to use, reproduce, display, distribute,
            execute, and transmit the Software, and to prepare derivative works of the
            Software, and to permit third-parties to whom the Software is furnished to
            do so, all subject to the following:

            The copyright notices in the Software and this entire statement, including
            the above license grant, this restriction and the following disclaimer,
            must be included in all copies of the Software, in whole or in part, and
            all derivative works of the Software, unless such copies or derivative
            works are solely in the form of machine-executable object code generated by
            a source language processor.

            THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
            IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
            FITNESS FOR A PARTICULAR PURPOSE, TITLE AND NON-INFRINGEMENT. IN NO EVENT
            SHALL THE COPYRIGHT HOLDERS OR ANYONE DISTRIBUTING THE SOFTWARE BE LIABLE
            FOR ANY DAMAGES OR OTHER LIABILITY, WHETHER IN CONTRACT, TORT OR OTHERWISE,
            ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
            DEALINGS IN THE SOFTWARE.
            """
        ),
        LicenseEntry(
            id: "openssl",
            name: "OpenSSL",
            summary: "Apache License 2.0 · embedded as OpenSSL.framework inside FluxDL.app",
            licenseText: """
            Apache License
            Version 2.0, January 2004
            http://www.apache.org/licenses/

            TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

            1. Definitions.

            "License" shall mean the terms and conditions for use, reproduction,
            and distribution as defined by Sections 1 through 9 of this document.

            "Licensor" shall mean the copyright owner or entity authorized by
            the copyright owner that is granting the License.

            "Legal Entity" shall mean the union of the acting entity and all
            other entities that control, are controlled by, or are under common
            control with that entity. For the purposes of this definition,
            "control" means (i) the power, direct or indirect, to cause the
            direction or management of such entity, whether by contract or
            otherwise, or (ii) ownership of fifty percent (50%) or more of the
            outstanding shares, or (iii) beneficial ownership of such entity.

            "You" (or "Your") shall mean an individual or Legal Entity
            exercising permissions granted by this License.

            "Source" form shall mean the preferred form for making modifications,
            including but not limited to software source code, documentation
            source, and configuration files.

            "Object" form shall mean any form resulting from mechanical
            transformation or translation of a Source form, including but
            not limited to compiled object code, generated documentation,
            and conversions to other media types.

            "Work" shall mean the work of authorship, whether in Source or
            Object form, made available under the License, as indicated by a
            copyright notice that is included in or attached to the work
            (an example is provided in the Appendix below).

            "Derivative Works" shall mean any work, whether in Source or
            Object form, that is based on (or derived from) the Work and for which the
            editorial revisions, annotations, elaborations, or other modifications
            represent, as a whole, an original work of authorship. For the purposes
            of this License, Derivative Works shall not include works that remain
            separable from, or merely link (or bind by name) to the interfaces of,
            the Work and Derivative Works thereof.

            "Contribution" shall mean any work of authorship, including
            the original version of the Work and any modifications or additions
            to that Work or Derivative Works thereof, that is intentionally
            submitted to Licensor for inclusion in the Work by the copyright owner
            or by an individual or Legal Entity authorized to submit on behalf of
            the copyright owner. For the purposes of this definition, "submitted"
            means any form of electronic, verbal, or written communication sent
            to the Licensor or its representatives, including but not limited to
            communication on electronic mailing lists, source code control systems,
            and issue tracking systems that are managed by, or on behalf of, the
            Licensor for the purpose of discussing and improving the Work, but
            excluding communication that is conspicuously marked or otherwise
            designated in writing by the copyright owner as "Not a Contribution."

            "Contributor" shall mean Licensor and any individual or Legal Entity
            on behalf of whom a Contribution has been received by Licensor and
            subsequently incorporated within the Work.

            2. Grant of Copyright License. Subject to the terms and conditions of
            this License, each Contributor hereby grants to You a perpetual,
            worldwide, non-exclusive, no-charge, royalty-free, irrevocable
            copyright license to reproduce, prepare Derivative Works of,
            publicly display, publicly perform, sublicense, and distribute the
            Work and such Derivative Works in Source or Object form.

            3. Grant of Patent License. Subject to the terms and conditions of
            this License, each Contributor hereby grants to You a perpetual,
            worldwide, non-exclusive, no-charge, royalty-free, irrevocable
            (except as stated in this section) patent license to make, have made,
            use, offer to sell, sell, import, and otherwise transfer the Work,
            where such license applies only to those patent claims licensable
            by such Contributor that are necessarily infringed by their
            Contribution(s) alone or by combination of their Contribution(s)
            with the Work to which such Contribution(s) was submitted. If You
            institute patent litigation against any entity (including a
            cross-claim or counterclaim in a lawsuit) alleging that the Work
            or a Contribution incorporated within the Work constitutes direct
            or contributory patent infringement, then any patent licenses
            granted to You under this License for that Work shall terminate
            as of the date such litigation is filed.

            4. Redistribution. You may reproduce and distribute copies of the
            Work or Derivative Works thereof in any medium, with or without
            modifications, and in Source or Object form, provided that You
            meet the following conditions:

            (a) You must give any other recipients of the Work or
            Derivative Works a copy of this License; and

            (b) You must cause any modified files to carry prominent notices
            stating that You changed the files; and

            (c) You must retain, in the Source form of any Derivative Works
            that You distribute, all copyright, patent, trademark, and
            attribution notices from the Source form of the Work,
            excluding those notices that do not pertain to any part of
            the Derivative Works; and

            (d) If the Work includes a "NOTICE" text file as part of its
            distribution, then any Derivative Works that You distribute must
            include a readable copy of the attribution notices contained
            within such NOTICE file, excluding those notices that do not
            pertain to any part of the Derivative Works, in at least one
            of the following places: within a NOTICE text file distributed
            as part of the Derivative Works; within the Source form or
            documentation, if provided along with the Derivative Works; or,
            within a display generated by the Derivative Works, if and
            wherever such third-party notices normally appear. The contents
            of the NOTICE file are for informational purposes only and
            do not modify the License. You may add Your own attribution
            notices within Derivative Works that You distribute, alongside
            or as an addendum to the NOTICE text from the Work, provided
            that such additional attribution notices cannot be construed
            as modifying the License.

            You may add Your own copyright statement to Your modifications and
            may provide additional or different license terms and conditions
            for use, reproduction, or distribution of Your modifications, or
            for any such Derivative Works as a whole, provided Your use,
            reproduction, and distribution of the Work otherwise complies with
            the conditions stated in this License.

            5. Submission of Contributions. Unless You explicitly state otherwise,
            any Contribution intentionally submitted for inclusion in the Work
            by You to the Licensor shall be under the terms and conditions of
            this License, without any additional terms or conditions.
            Notwithstanding the above, nothing herein shall supersede or modify
            the terms of any separate license agreement you may have executed
            with Licensor regarding such Contributions.

            6. Trademarks. This License does not grant permission to use the trade
            names, trademarks, service marks, or product names of the Licensor,
            except as required for reasonable and customary use in describing the
            origin of the Work and reproducing the content of the NOTICE file.

            7. Disclaimer of Warranty. Unless required by applicable law or
            agreed to in writing, Licensor provides the Work (and each
            Contributor provides its Contributions) on an "AS IS" BASIS,
            WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
            implied, including, without limitation, any warranties or conditions
            of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
            PARTICULAR PURPOSE. You are solely responsible for determining the
            appropriateness of using or redistributing the Work and assume any
            risks associated with Your exercise of permissions under this License.

            8. Limitation of Liability. In no event and under no legal theory,
            whether in tort (including negligence), contract, or otherwise,
            unless required by applicable law (such as deliberate and grossly
            negligent acts) or agreed to in writing, shall any Contributor be
            liable to You for damages, including any direct, indirect, special,
            incidental, or consequential damages of any character arising as a
            result of this License or out of the use or inability to use the
            Work (including but not limited to damages for loss of goodwill,
            work stoppage, computer failure or malfunction, or any and all
            other commercial damages or losses), even if such Contributor
            has been advised of the possibility of such damages.

            9. Accepting Warranty or Additional Liability. While redistributing
            the Work or Derivative Works thereof, You may choose to offer,
            and charge a fee for, acceptance of support, warranty, indemnity,
            or other liability obligations and/or rights consistent with this
            License. However, in accepting such obligations, You may act only
            on Your own behalf and on Your sole responsibility, not on behalf
            of any other Contributor, and only if You agree to indemnify,
            defend, and hold each Contributor harmless for any liability
            incurred by, or claims asserted against, such Contributor by reason
            of your accepting any such warranty or additional liability.

            END OF TERMS AND CONDITIONS
            """
        )
    ]
}
