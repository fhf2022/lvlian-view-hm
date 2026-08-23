import { cryptoFramework } from '@kit.CryptoArchitectureKit'
import { util } from '@kit.ArkTS'

export class UgreenCrypto {
  static async encryptBase64(plainText: string, encodedPem: string): Promise<string> {
    const pem = UgreenCrypto.decodePem(encodedPem)
    const keyAlgorithms: string[] = ['RSA2048', 'RSA1024', 'RSA3072', 'RSA4096']
    let keyPair: cryptoFramework.KeyPair | null = null
    let keyError: Object | null = null
    for (const keyAlgorithm of keyAlgorithms) {
      try {
        const keyGenerator = cryptoFramework.createAsyKeyGenerator(keyAlgorithm)
        keyPair = await keyGenerator.convertPemKey(pem, null)
        break
      } catch (error) {
        keyError = error as Object
      }
    }
    if (keyPair === null) {
      throw new Error('RSA 公钥转换失败: ' + String(keyError))
    }
    const encoder = new util.TextEncoder()
    const input: cryptoFramework.DataBlob = { data: encoder.encodeInto(plainText) }
    const algorithms: string[] = [
      'RSA2048|PKCS1',
      'RSA1024|PKCS1',
      'RSA3072|PKCS1',
      'RSA4096|PKCS1'
    ]
    let lastError: Object | null = null
    for (const algorithm of algorithms) {
      try {
        const cipher = cryptoFramework.createCipher(algorithm)
        await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, keyPair.pubKey, null)
        const output = await cipher.doFinal(input)
        return new util.Base64Helper().encodeToStringSync(output.data)
      } catch (error) {
        lastError = error as Object
      }
    }
    throw new Error('RSA加密失败: ' + String(lastError))
  }

  private static decodePem(value: string): string {
    if (value.includes('BEGIN PUBLIC KEY') || value.includes('BEGIN RSA PUBLIC KEY')) {
      return value
    }
    try {
      const bytes = new util.Base64Helper().decodeSync(value)
      const decoder = new util.TextDecoder('utf-8', { ignoreBOM: true })
      const decoded = decoder.decodeToString(bytes)
      if (decoded.includes('BEGIN PUBLIC KEY') || decoded.includes('BEGIN RSA PUBLIC KEY')) {
        return decoded
      }
    } catch (_error) {
    }
    return value
  }
}
