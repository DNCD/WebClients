import XCTest
@testable import MailClient

final class DecodingTests: XCTestCase {
    func testCamelCasesProtonKeys() {
        XCTAssertEqual(ProtonCodingKey.camelCase("ID"), "id")
        XCTAssertEqual(ProtonCodingKey.camelCase("UID"), "uid")
        XCTAssertEqual(ProtonCodingKey.camelCase("AddressID"), "addressID")
        XCTAssertEqual(ProtonCodingKey.camelCase("SRPSession"), "srpSession")
        XCTAssertEqual(ProtonCodingKey.camelCase("MIMEType"), "mimeType")
        XCTAssertEqual(ProtonCodingKey.camelCase("CCList"), "ccList")
        XCTAssertEqual(ProtonCodingKey.camelCase("2FA"), "2FA")
    }

    func testDecodesAuthResponse() throws {
        let json = """
        {"Code":1000,"UID":"u","AccessToken":"a","RefreshToken":"r","ServerProof":"cA==","PasswordMode":2,
         "2FA":{"Enabled":1},"Scopes":["full"]}
        """
        let response = try JSONDecoder.proton.decode(AuthResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.uid, "u")
        XCTAssertTrue(response.needsMailboxPassword)
        XCTAssertEqual(response.twoFactor?.totp, true)
    }

    func testDecodesMessageMetadata() throws {
        let json = """
        {"Code":1000,"Total":1,"Messages":[{"ID":"m1","ConversationID":"c1","AddressID":"a1","Subject":"Hi",
          "Sender":{"Name":"Ann","Address":"ann@example.com"},"ToList":[{"Name":"","Address":"me@example.com"}],
          "CCList":[],"Time":1700000000,"Size":10,"Unread":1,"NumAttachments":0,"Flags":1,"LabelIDs":["0"]}]}
        """
        let response = try JSONDecoder.proton.decode(MessagesResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.messages.first?.sender.address, "ann@example.com")
        XCTAssertEqual(response.messages.first?.isUnread, true)
    }
}

final class MultipartFormTests: XCTestCase {
    func testFlattensNestedKeysLikeWebClient() {
        var form = MultipartForm(boundary: "B")
        let package: [String: Any] = ["Type": 1, "Addresses": ["a@b.c": ["Type": 1]]]
        form.appendNested("Packages", ["text/plain": package])
        XCTAssertEqual(form.fields.map(\.name), [
            "Packages[text/plain][Addresses][a@b.c][Type]",
            "Packages[text/plain][Type]",
        ])
        let body = String(decoding: form.encoded(), as: UTF8.self)
        XCTAssertTrue(body.hasSuffix("--B--\r\n"))
    }
}

final class MIMEParserTests: XCTestCase {
    func testPrefersHTMLPartAndDecodesQuotedPrintable() {
        let mime = """
        Content-Type: multipart/mixed;
         boundary="outer"

        --outer
        Content-Type: multipart/alternative; boundary="inner"

        --inner
        Content-Type: text/plain; charset=utf-8

        plain version
        --inner
        Content-Type: text/html; charset=utf-8
        Content-Transfer-Encoding: quoted-printable

        <p>caf=C3=A9 =
        ok</p>
        --inner--
        --outer
        Content-Type: application/pdf
        Content-Disposition: attachment; filename="a.pdf"

        JVBERi0=
        --outer--
        """
        guard case .html(let html) = MIMEParser.content(of: mime) else {
            return XCTFail("Expected HTML")
        }
        XCTAssertEqual(html, "<p>café ok</p>")
    }

    func testFallsBackToBase64PlainText() {
        let mime = "Content-Type: text/plain\nContent-Transfer-Encoding: base64\n\naGVsbG8="
        guard case .plain(let text) = MIMEParser.content(of: mime) else {
            return XCTFail("Expected plain text")
        }
        XCTAssertEqual(text, "hello")
    }
}

final class ComposeTests: XCTestCase {
    func testParsesRecipientList() {
        XCTAssertEqual(ComposeView.emails("a@x.com, b@y.org;  nope c@z.net"), ["a@x.com", "b@y.org", "c@z.net"])
    }

    func testStripsHTMLForQuoting() {
        XCTAssertEqual("<style>p{}</style><p>Hi&nbsp;there</p><br>Bye".strippingHTML(), "Hi there\n\nBye")
    }
}

/// Exercises the real GopenPGP bindings to check the send/receive formats round-trip.
final class CryptoTests: XCTestCase {
    override class func setUp() {
        Crypto.setUp()
    }

    private func makeAddressKeys(email: String, passphrase: String = "secret") throws -> (MailKeys.AddressKeys, String) {
        let armored = try Crypto.generateKey(email: email, passphrase: passphrase)
        let unlocked = try Crypto.key(armored: armored).unlock(Data(passphrase.utf8))
        let publicKey = try Crypto.call { unlocked.getArmoredPublicKey($0) }
        let keys = MailKeys.AddressKeys(
            decryptionRing: try Crypto.keyRing([unlocked]),
            signingRing: try Crypto.keyRing([unlocked]),
            encryptionRing: try Crypto.publicKeyRing(armored: publicKey)
        )
        return (keys, publicKey)
    }

    func testKeyPassphraseIs31Characters() throws {
        let salt = Data(repeating: 7, count: 16).base64EncodedString()
        XCTAssertEqual(try Crypto.keyPassphrase(password: "hunter2", keySalt: salt).count, 31)
        XCTAssertEqual(try Crypto.keyPassphrase(password: "hunter2", keySalt: nil), "hunter2")
    }

    func testDraftBodyDecryptsWithOwnKeys() throws {
        let (keys, _) = try makeAddressKeys(email: "me@example.com")
        let armored = try SendEncryption.encryptDraftBody("Hello draft", keys: keys)
        XCTAssertEqual(try Crypto.decrypt(armored: armored, with: keys.decryptionRing), "Hello draft")
    }

    func testPackageBodyDecryptsForProtonRecipientAndCarriesClearKey() throws {
        let (sender, _) = try makeAddressKeys(email: "me@example.com")
        let (recipient, recipientPublicKey) = try makeAddressKeys(email: "you@example.com")

        let package = try SendEncryption.plainTextPackage(
            body: "Hello there",
            recipients: ["you@example.com": .proton(publicKey: recipientPublicKey), "ext@example.org": .clear],
            keys: sender
        )
        XCTAssertEqual(package["Type"] as? Int, PackageType.sendPM | PackageType.sendClear)
        XCTAssertNotNil(package["BodyKey"])

        let addresses = try XCTUnwrap(package["Addresses"] as? [String: [String: Any]])
        let keyPacket = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(addresses["you@example.com"]?["BodyKeyPacket"] as? String)))
        let dataPacket = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(package["Body"] as? String)))

        let sessionKey = try recipient.decryptionRing.decryptSessionKey(keyPacket)
        XCTAssertEqual(try sessionKey.decrypt(dataPacket).getString(), "Hello there")
    }
}

final class LinkCleanerTests: XCTestCase {
    func testRemovesTrackingParametersAndKeepsOthers() throws {
        let link = try XCTUnwrap(LinkCleaner.clean("https://shop.example.com/item?id=42&utm_source=news&utm_medium=email&fbclid=abc&q=a%26b#top"))
        XCTAssertEqual(link.cleaned, "https://shop.example.com/item?id=42&q=a%26b#top")
        XCTAssertEqual(Set(link.removed), ["utm_source", "utm_medium", "fbclid"])
    }

    func testLeavesCleanAndNonHTTPLinksAlone() {
        XCTAssertNil(LinkCleaner.clean("https://example.com/page?id=1"))
        XCTAssertNil(LinkCleaner.clean("mailto:someone@example.com?subject=utm_source"))
    }

    func testDropsQueryWhenOnlyTrackingParameters() {
        XCTAssertEqual(LinkCleaner.clean("https://example.com/?utm_campaign=x")?.cleaned, "https://example.com/")
    }

    func testCleansLinksInPlainText() {
        let result = LinkCleaner.cleanText("Read https://example.com/a?utm_source=x and https://example.com/b")
        XCTAssertEqual(result.text, "Read https://example.com/a and https://example.com/b")
        XCTAssertEqual(result.cleaned.count, 1)
    }
}

final class HTMLPrivacyTests: XCTestCase {
    func testRoutesImagesThroughProxyAndFlagsPixels() {
        let html = """
        <p><img src="https://cdn.example.com/logo.png" srcset="https://cdn.example.com/logo@2x.png 2x" alt="Logo">
        <img width="1" height="1" src="https://track.example.net/open?u=1&amp;m=2">
        <img src="data:image/png;base64,AAAA"></p>
        <div style="background-image:url('https://cdn.example.com/bg.jpg')"></div>
        """
        let result = HTMLPrivacy.process(html)

        XCTAssertFalse(result.html.contains(#"src="https://"#))
        XCTAssertFalse(result.html.contains("srcset"))
        XCTAssertFalse(result.html.contains("url('https://"))
        XCTAssertTrue(result.html.contains("data:image/png;base64,AAAA"))
        XCTAssertEqual(result.remoteImages, [
            RemoteImage(url: "https://cdn.example.com/logo.png", isLikelyPixel: false),
            RemoteImage(url: "https://track.example.net/open?u=1&m=2", isLikelyPixel: true),
            RemoteImage(url: "https://cdn.example.com/bg.jpg", isLikelyPixel: false),
        ])
    }

    func testProxyURLRoundTrips() throws {
        let remote = "https://track.example.net/open?u=1&m=2"
        let components = try XCTUnwrap(URLComponents(string: HTMLPrivacy.proxyURL(for: remote)))
        XCTAssertEqual(components.scheme, "pm-proxy")
        XCTAssertEqual(components.queryItems?.first { $0.name == "url" }?.value, remote)
    }

    func testCleansTrackingLinks() {
        let result = HTMLPrivacy.process(#"<a class="btn" href="https://example.com/sale?utm_source=nl&amp;id=7">Shop</a>"#)
        XCTAssertEqual(result.html, #"<a class="btn" href="https://example.com/sale?id=7">Shop</a>"#)
        XCTAssertEqual(result.cleanedLinks.first?.removed, ["utm_source"])
    }

    func testPixelHeuristics() {
        XCTAssertTrue(HTMLPrivacy.isLikelyPixel(#"<img src="x" style="display: none">"#))
        XCTAssertTrue(HTMLPrivacy.isLikelyPixel(#"<img src="x" style="width:1px;height:1px">"#))
        XCTAssertFalse(HTMLPrivacy.isLikelyPixel(#"<img src="x" width="120" height="40">"#))
        XCTAssertFalse(HTMLPrivacy.isLikelyPixel(#"<img src="x" style="opacity:0.5">"#))
    }
}
