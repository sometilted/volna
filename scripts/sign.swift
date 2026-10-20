// Подпись обновлений ed25519 (CryptoKit). Запуск: swift scripts/sign.swift keygen | sign <файл> | verify <файл> <sig>
// Приватный ключ лежит только у автора: ~/.config/volna/release_ed25519 (вне репозитория).
import CryptoKit
import Foundation

let keyURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/volna/release_ed25519")
let args = CommandLine.arguments.dropFirst()

func die(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(1) }

func loadKey() -> Curve25519.Signing.PrivateKey {
    guard let s = try? String(contentsOf: keyURL, encoding: .utf8),
          let d = Data(base64Encoded: s.trimmingCharacters(in: .whitespacesAndNewlines)),
          let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: d) else {
        die("[Ошибка] нет ключа \(keyURL.path) — сначала: swift scripts/sign.swift keygen")
    }
    return k
}

switch args.first {
case "keygen":
    if FileManager.default.fileExists(atPath: keyURL.path) {
        print("[Есть] ключ уже создан, публичный: \(loadKey().publicKey.rawRepresentation.base64EncodedString())")
        exit(0)
    }
    let k = Curve25519.Signing.PrivateKey()
    try? FileManager.default.createDirectory(at: keyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! k.rawRepresentation.base64EncodedString().write(to: keyURL, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
    print(k.publicKey.rawRepresentation.base64EncodedString())
case "pub":
    print(loadKey().publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard let f = args.dropFirst().first, let data = FileManager.default.contents(atPath: f) else { die("[Ошибка] нет файла") }
    print(try! loadKey().signature(for: data).base64EncodedString())
case "verify":
    let rest = Array(args.dropFirst())
    guard rest.count == 2, let data = FileManager.default.contents(atPath: rest[0]),
          let sigText = try? String(contentsOfFile: rest[1], encoding: .utf8),
          let sig = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines)) else { die("[Ошибка] verify <файл> <sig>") }
    print(loadKey().publicKey.isValidSignature(sig, for: data) ? "[Подпись] верна" : "[Подпись] НЕ верна")
default:
    die("swift scripts/sign.swift keygen | pub | sign <файл> | verify <файл> <sig>")
}
