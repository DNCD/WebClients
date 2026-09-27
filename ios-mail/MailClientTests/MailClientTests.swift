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
