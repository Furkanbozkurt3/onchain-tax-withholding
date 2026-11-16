import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

/**
 * Deploys TaxWithholdingPayments.
 *
 * Parameters (see ignition/parameters.example.json):
 *   owner         - administrator of rates, tokens and the tax authority address
 *   taxAuthority  - address that receives withheld taxes
 *
 * Categories and allowed tokens are added afterwards by the owner
 * (addCategory / setTokenAllowed), so every rate change is a visible transaction.
 */
export default buildModule("TaxWithholdingPaymentsModule", (m) => {
  const owner = m.getParameter<string>("owner");
  const taxAuthority = m.getParameter<string>("taxAuthority");

  const payments = m.contract("TaxWithholdingPayments", [owner, taxAuthority]);

  return { payments };
});
