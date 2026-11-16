# Onchain Tax Withholding · Vergi Kesintili Ödeme Kontratı

> ⚠️ **Educational project. Not audited. Not tax or legal advice. Example rates are illustrative.**
> ⚠️ **Eğitim amaçlı proje. Güvenlik denetiminden geçmedi. Vergi ya da hukuk tavsiyesi değildir. Örnek oranlar temsilîdir.**

[Türkçe](#türkçe) · [English](#english)

---

## Türkçe

Bir faturanın ödemesini **tek işlemde** bölen bir Solidity akıllı kontratı: alıcı net tutarı, vergi dairesi kesilen vergileri (KDV tevkifatı ve gelir vergisi stopajı) aynı anda alır. Kontrat parayı hiç elinde tutmaz; tutar ödeyenin hesabından doğrudan alıcıya ve vergi dairesine aktarılır.

### Neden?

Tevkifat ve stopajda vergi ödeme anında kesilir ama vergi dairesine ayrı bir beyan ve ödeme adımıyla, genellikle sonraki ay ulaşır. Bu proje, kesinti ile ödemenin aynı işlemde yapıldığı ve her ödemenin herkesçe doğrulanabilir bir makbuz bıraktığı bir modeli kavram kanıtı olarak gösterir.

### Hesap

| Kalem | Formül |
|---|---|
| KDV | matrah × KDV oranı |
| KDV tevkifatı | KDV × pay / payda (ör. 9/10) |
| Stopaj | matrah × stopaj oranı |
| Ödeyenin ödediği | matrah + KDV |
| Vergi dairesine | KDV tevkifatı + stopaj |
| Alıcıya (net) | matrah + KDV − KDV tevkifatı − stopaj |

Örnek (matrah 10.000, `npx hardhat run scripts/demo.ts` çıktısı):

| İşlem türü (örnek oranlar) | Ödeyen öder | Alıcıya | Vergi dairesine |
|---|---:|---:|---:|
| İşyeri kirası, bireyden (KDV yok, stopaj %20) | 10.000 | 8.000 | 2.000 |
| Temizlik hizmeti (KDV %20, tevkifat 9/10) | 12.000 | 10.200 | 1.800 |
| Serbest meslek / avukat (KDV %20, stopaj %20) | 12.000 | 10.000 | 2.000 |

Oranlar koda gömülü değildir; her işlem türü (kategori) için yönetici tarafından ayarlanır. Gerçek oranlar mevzuata (GVK md. 94, KDV Genel Uygulama Tebliği) göre değişir ve doğrulanmalıdır.

### Korumalar

- **Yürürlük tarihi:** Mevcut bir kategorinin oranı ya da vergi dairesi adresi en az **1 gün önceden** ilan edilmeden değişemez (mevzuattaki yayım / yürürlük ayrımı gibi). İlan iptal edilebilir.
- **Sürüm sabitleme:** Ödeyen, kabul ettiği kural sürümünü ve vergi dairesi adresini işleme yazar (`quote` çıktısı); biri arada değiştiyse ödeme geri döner.
- **Mükerrer ödeme engeli:** Bir ödeyen aynı fatura parmak izini (hash) ikinci kez ödeyemez. Kayıt ödeyene bağlıdır; böylece üçüncü bir kişi faturanın hash'ini önden küçük bir ödemeyle kilitleyemez (front-running).
- **Para tutmaz:** Bakiye her zaman sıfırdır (invariant testiyle sınandı); alıcı olarak kontratın kendi adresi verilemez.
- **Mahremiyet:** Zincire faturanın kendisi değil, yalnız parmak izi yazılır. Adresler ve tutarlar herkese açıktır.
- Reentrancy koruması, acil durdurma (pause), yalnız onaylı token, iki adımlı sahiplik devri; sahipliği bırakma (renounce) kapalı.

### Testler

38 Solidity testi (Hardhat 3, forge-std):

- **33 birim ve saldırı testi:** mükerrer ödeme, faturayı önden kilitleme (front-running), yetkisiz oran değişikliği, süresi dolmadan oran uygulama, eski sürümle ya da eski vergi dairesi adresiyle ödeme, geri çağıran (reentrant) kötü token, onaysız token, eksik onay (allowance), kontrata para kilitleme, geçersiz oranlar.
- **2 fuzz testi (her biri 1.000 çalışma):** rastgele tutar ve oranlarla (KDV'siz ve tevkifatsız kurallar dahil) "ödenen = alıcıya giden + vergi dairesine giden"; rastgele yanlış sürümle ödemenin reddi.
- **3 invariant testi:** rastgele ödeme / oran değişikliği / vergi dairesi değişikliği / zaman atlama dizilerinde kontrat bakiyesi hep sıfır, değer korunuyor, makbuz sayısı ödeme sayısına eşit.

### Kurulum ve çalıştırma

Gereken: Node.js 22+.

```bash
npm install
npx hardhat test                 # tüm testler
npx hardhat run scripts/demo.ts  # yerel demo (gerçek ağa bir şey gönderilmez)
```

Yayına alma (isteğe bağlı, test ağı): anahtarlar koda değil Hardhat keystore'a yazılır.

```bash
npx hardhat keystore set SEPOLIA_RPC_URL
npx hardhat keystore set SEPOLIA_PRIVATE_KEY
cp ignition/parameters.example.json ignition/parameters.json   # owner ve taxAuthority adreslerini yaz
npx hardhat ignition deploy ignition/modules/TaxWithholdingPayments.ts --network sepolia --parameters ignition/parameters.json
```

Ardından yönetici `setTokenAllowed` ile ödeme tokenını, `addCategory` ile işlem türlerini ekler.

### Bilinen sınırlar

- **Gerçeklik sorunu (oracle):** Kontrat, faturanın gerçek bir mal ya da hizmet teslimine dayandığını bilemez; yalnız ödemeyi ve kesintiyi doğru böler.
- **Hukuki çerçeve:** Türkiye'de kripto varlıklar ödemede kullanılamaz (TCMB, 2021). Bu proje bir kavram kanıtıdır; gerçek bir uygulama ancak bir dijital para birimi (ör. merkez bankası dijital parası) ve idarenin kendi altyapısıyla mümkün olabilir.
- Yalnız düz ERC-20 tokenlar desteklenir; transferde kesinti yapan (fee-on-transfer), bakiyesi kendiliğinden değişen (rebasing) ya da geri çağrı yapan tokenlar desteklenmez.
- **Yuvarlama:** Tutarlar tokenın en küçük birimine aşağı yuvarlanır; kalem başına en fazla 1 birimlik kırıntı alıcıda kalır. Türkiye uygulamasında kuruşa yuvarlanır; 18 ondalıklı tokenda fark ihmal edilebilir.
- Yönetici güvenilir bir taraftır (yeni kategoriyi hemen ekleyebilir, token onaylayabilir, durdurabilir); gerçek kullanımda çoklu imza (multisig) cüzdan önerilir.

---

## English

A Solidity smart contract that splits an invoice payment **in a single transaction**: the payee receives the net amount and the tax authority receives the withheld taxes (VAT withholding and income tax withholding) at the same time. The contract never holds funds; tokens move straight from the payer to the payee and the tax authority.

### Why?

With withholding taxes, tax is deducted at the time of payment but reaches the tax authority later through a separate filing and payment step. This project is a proof of concept where the deduction and the remittance happen in the same transaction and every payment leaves a publicly verifiable receipt.

### Formula

| Item | Formula |
|---|---|
| VAT | base × VAT rate |
| VAT withholding | VAT × numerator / denominator (e.g. 9/10) |
| Income tax withholding | base × withholding rate |
| Payer pays | base + VAT |
| Tax authority receives | VAT withholding + income tax withholding |
| Payee receives (net) | base + VAT − VAT withholding − income tax withholding |

Example with a base of 10,000 (output of `npx hardhat run scripts/demo.ts`):

| Category (illustrative rates) | Payer pays | Payee | Tax authority |
|---|---:|---:|---:|
| Workplace rent from an individual (no VAT, 20% withholding) | 10,000 | 8,000 | 2,000 |
| Cleaning service (20% VAT, 9/10 VAT withheld) | 12,000 | 10,200 | 1,800 |
| Self-employed / lawyer fee (20% VAT, 20% withholding) | 12,000 | 10,000 | 2,000 |

Rates are not hard-coded; the owner configures them per payment category. Real rates depend on current Turkish legislation and must be verified.

### Safeguards

- **Effective dates:** rates of an existing category and the tax authority address can only change with at least **1 day of notice**, like a law that is published before it takes effect. Announcements can be cancelled.
- **Version pinning:** the payer passes the rule version and tax authority address they agreed to (from `quote`); the payment reverts if either changed.
- **No double payment:** a payer can pay an invoice hash only once. Records are keyed by payer, so a third party cannot front-run and lock someone else's invoice hash with a dust payment.
- **No custody:** the contract balance is always zero (checked by invariant tests); the contract itself cannot be the payee.
- **Privacy:** only the invoice hash goes on chain, never the invoice. Addresses and amounts are public.
- Reentrancy guard, pause switch, token allowlist, two-step ownership transfer; renouncing ownership is disabled.

### Tests

38 Solidity tests (Hardhat 3, forge-std):

- **33 unit and attack tests:** double payment, front-running an invoice, unauthorized rate change, early activation, stale rule version or tax authority, reentrant malicious token, non-allowed token, insufficient allowance, funds locked in the contract, invalid rates.
- **2 fuzz tests (1,000 runs each):** random amounts and rates (including rules without VAT or withholding), "paid = received by payee + received by tax authority"; any wrong rule version is rejected.
- **3 invariant tests:** across random sequences of payments, rule changes, tax authority changes and time jumps the contract balance stays zero, value is conserved and receipts match payments.

### Getting started

Requires Node.js 22+.

```bash
npm install
npx hardhat test                 # all tests
npx hardhat run scripts/demo.ts  # local demo, nothing is sent to a real network
```

Deployment (optional, testnet): secrets go to the Hardhat keystore, never to source code.

```bash
npx hardhat keystore set SEPOLIA_RPC_URL
npx hardhat keystore set SEPOLIA_PRIVATE_KEY
cp ignition/parameters.example.json ignition/parameters.json   # set owner and taxAuthority
npx hardhat ignition deploy ignition/modules/TaxWithholdingPayments.ts --network sepolia --parameters ignition/parameters.json
```

The owner then allows the payment token with `setTokenAllowed` and adds categories with `addCategory`.

### Known limitations

- **Oracle problem:** the contract cannot know whether an invoice reflects a real delivery of goods or services; it only splits the payment correctly.
- **Legal context:** crypto assets cannot be used for payments in Türkiye (Central Bank regulation, 2021). This is a proof of concept; a real system would need a digital currency such as a central bank digital currency and the tax administration's own infrastructure.
- Only plain ERC-20 tokens are supported (no fee-on-transfer, rebasing or callback tokens).
- **Rounding:** amounts are rounded down to the token's smallest unit; at most 1 unit of dust per tax item stays with the payee. Turkish practice rounds to the kuruş; with an 18-decimal token the difference is negligible.
- The owner is trusted (can add a new category immediately, allow tokens, pause); a multisig wallet is recommended for real use.

### Project layout

```
contracts/TaxWithholdingPayments.sol   main contract
contracts/mocks/                       test / demo tokens (never deploy)
test/                                  unit, attack, fuzz and invariant tests
scripts/demo.ts                        local demo
ignition/modules/                      deployment module
```

## License

[MIT](LICENSE) © 2026 Furkan Bozkurt
