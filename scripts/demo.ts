/**
 * Local demo on Hardhat's in-process network. Nothing is sent to a real chain.
 *
 *   npx hardhat run scripts/demo.ts
 *
 * Deploys a mock stablecoin and the contract, adds three example categories
 * (illustrative rates) and pays one invoice in each, printing the split.
 */
import { network } from "hardhat";
import { formatUnits, keccak256, parseUnits, stringToHex, toHex } from "viem";

const { viem } = await network.create();
const [owner, taxOffice, payer, landlord, cleaner, lawyer] = await viem.getWalletClients();

const token = await viem.deployContract("MockERC20");
const payments = await viem.deployContract("TaxWithholdingPayments", [
  owner.account.address,
  taxOffice.account.address,
]);

const cat = (name: string) => toHex(name, { size: 32 });
const categories = [
  { id: cat("RENT"), label: "Workplace rent (stopaj 20%)", args: [0, 0, 0, 2000] as const, payee: landlord },
  { id: cat("CLEANING"), label: "Cleaning service (VAT 20%, 9/10 withheld)", args: [2000, 9, 10, 0] as const, payee: cleaner },
  { id: cat("FREELANCE"), label: "Lawyer fee (VAT 20%, stopaj 20%)", args: [2000, 0, 0, 2000] as const, payee: lawyer },
];

await payments.write.setTokenAllowed([token.address, true]);
for (const c of categories) {
  await payments.write.addCategory([c.id, ...c.args]);
}

await token.write.mint([payer.account.address, parseUnits("100000", 18)]);
const tokenAsPayer = await viem.getContractAt("MockERC20", token.address, { client: { wallet: payer } });
const paymentsAsPayer = await viem.getContractAt("TaxWithholdingPayments", payments.address, {
  client: { wallet: payer },
});
await tokenAsPayer.write.approve([payments.address, parseUnits("100000", 18)]);

const fmt = (v: bigint) => Number(formatUnits(v, 18)).toLocaleString("en-US", { minimumFractionDigits: 2 });
const base = parseUnits("10000", 18);

console.log("\nInvoice base amount: 10,000.00 mUSD in every case\n");
for (const [i, c] of categories.entries()) {
  const [b, version, taxAuthority] = await payments.read.quote([c.id, base]);
  const invoiceHash = keccak256(stringToHex(`DEMO-INVOICE-${i + 1}`));
  await paymentsAsPayer.write.pay([invoiceHash, c.id, token.address, c.payee.account.address, base, version, taxAuthority]);

  console.log(c.label);
  console.log(`  payer pays (base + VAT) : ${fmt(b.grossAmount)}`);
  console.log(`  VAT                     : ${fmt(b.vatAmount)}`);
  console.log(`  VAT withheld            : ${fmt(b.vatWithheld)}`);
  console.log(`  income tax withheld     : ${fmt(b.incomeTaxWithheld)}`);
  console.log(`  -> payee receives       : ${fmt(b.netAmount)}`);
  console.log(`  -> tax office receives  : ${fmt(b.taxAmount)}\n`);
}

const contractBalance = await token.read.balanceOf([payments.address]);
console.log(`Tax office balance : ${fmt(await token.read.balanceOf([taxOffice.account.address]))}`);
console.log(`Contract balance   : ${fmt(contractBalance)} (the contract never holds funds)`);
console.log(`Receipts issued    : ${await payments.read.receiptCount()}`);

// A second payment of the same invoice is rejected.
try {
  await paymentsAsPayer.write.pay([
    keccak256(stringToHex("DEMO-INVOICE-1")),
    categories[0].id,
    token.address,
    landlord.account.address,
    base,
    1,
    taxOffice.account.address,
  ]);
  console.log("Duplicate payment  : ACCEPTED (unexpected)");
} catch {
  console.log("Duplicate payment  : rejected (InvoiceAlreadyPaid)");
}
