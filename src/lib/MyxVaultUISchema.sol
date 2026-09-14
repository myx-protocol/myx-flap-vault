// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {VaultUISchema, VaultMethodSchema, FieldDescriptor} from "../flap/IVaultSchemasV1.sol";

/// @title MyxVaultUISchema
/// @notice Builds the Flap VaultBaseV2 UI schema for MyxVault. Lives in an externally linked library
///         (public function => DELEGATECALL into a separately deployed contract) so the ~4.5 KB of
///         bilingual method descriptions do not count against MyxVault's EIP-170 runtime limit.
///         Pure data; touches no vault storage.
library MyxVaultUISchema {
    function build() public pure returns (VaultUISchema memory schema) {
        schema.vaultType = "MyxVault";
        schema.description =
            unicode"Tax revenue is converted to MYX LP and distributed to holders as dividends. / 稅收轉換為 MYX LP，作為分紅分配給持幣者。";
        schema.methods = new VaultMethodSchema[](11);

        schema.methods[0].name = "pendingQuote";
        schema.methods[0].description =
            unicode"Tax revenue awaiting processing, in quote token units. / 待處理的稅收金額（報價幣單位）。";
        schema.methods[0].outputs = new FieldDescriptor[](1);
        schema.methods[0].outputs[0] = FieldDescriptor("amount", "uint256", "Quote amount", 0);

        schema.methods[1].name = "requestProcess";
        schema.methods[1].description =
            unicode"Schedule a buyback: the Flap trigger service then buys back the token with the pending quote revenue, deposits into MYX pool, and feeds LP to dividends. Anyone may call; ERC20-quote vaults may attach BNB for the trigger fee. / 預約回購：由 Flap 觸發服務用待處理稅收回購代幣、注入 MYX 池並分發 LP 分紅。任何人可調用；ERC20 報價幣金庫可附帶 BNB 作觸發手續費。";
        schema.methods[1].isWriteMethod = true;

        schema.methods[2].name = "feedDividend";
        schema.methods[2].description =
            unicode"Feed held mBase LP into the dividend contract. Permissionless; retries a deferred feed. / 將持有的 mBase LP 注入分紅合約。任何人可調用，可重試延遲分發。";
        schema.methods[2].isWriteMethod = true;

        schema.methods[3].name = "claimReward";
        schema.methods[3].description =
            unicode"Claim your mBase LP dividend. You may also claim directly on the dividend contract. / 領取您的 mBase LP 分紅，也可直接在分紅合約上領取。";
        schema.methods[3].isWriteMethod = true;

        schema.methods[4].name = "pendingReward";
        schema.methods[4].description = unicode"Claimable mBase LP dividend for a holder. / 持幣者可領取的 mBase LP 分紅金額。";
        schema.methods[4].inputs = new FieldDescriptor[](1);
        schema.methods[4].inputs[0] = FieldDescriptor("user", "address", "Holder address", 0);
        schema.methods[4].outputs = new FieldDescriptor[](1);
        schema.methods[4].outputs[0] = FieldDescriptor("amount", "uint256", "Claimable LP amount", 18);

        schema.methods[5].name = "vaultQuoteToken";
        schema.methods[5].description =
            unicode"Revenue currency of this vault (zero address = native). / 本金庫的稅收幣種（零地址為原生幣）。";
        schema.methods[5].outputs = new FieldDescriptor[](1);
        schema.methods[5].outputs[0] = FieldDescriptor("quoteToken", "address", "Quote token", 0);

        schema.methods[6].name = "sync";
        schema.methods[6].description =
            unicode"Recognize quote revenue that arrived without a wake call. Permissionless. / 確認未觸發喚醒的稅收入賬。任何人可調用。";
        schema.methods[6].isWriteMethod = true;

        schema.methods[7].name = "fundGas";
        schema.methods[7].description =
            unicode"Top up the BNB gas pool that pays auto-trigger fees (ERC20 quote vaults). / 為自動觸發手續費充值 BNB Gas 池（ERC20 報價幣金庫）。";
        schema.methods[7].isWriteMethod = true;

        schema.methods[8].name = "gasBalance";
        schema.methods[8].description = unicode"BNB reserved for auto-trigger fees. / 保留給自動觸發手續費的 BNB。";
        schema.methods[8].outputs = new FieldDescriptor[](1);
        schema.methods[8].outputs[0] = FieldDescriptor("amount", "uint256", "BNB amount", 18);

        schema.methods[9].name = "poolReady";
        schema.methods[9].description =
            unicode"Auto-buyback switch: true once the MYX pool exists. Until then tax accumulates and no buyback is scheduled. / 自動回購開關：MYX 池部署後為 true；在此之前稅收只累積，不預約回購。";
        schema.methods[9].outputs = new FieldDescriptor[](1);
        schema.methods[9].outputs[0] = FieldDescriptor("ready", "bool", "Pool deployed", 0);

        schema.methods[10].name = "ensurePoolDeployed";
        schema.methods[10].description =
            unicode"Deploy the MYX pool (if missing), open the auto-buyback switch and schedule any accumulated tax. Permissionless; needs ~2.1M gas on first use. / 部署 MYX 池（若尚未部署）、打開自動回購開關並預約已累積的稅收。任何人可調用；首次約需 210 萬 gas。";
        schema.methods[10].isWriteMethod = true;
    }
}
