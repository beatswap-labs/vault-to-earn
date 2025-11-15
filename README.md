# Vault-to-Earn

A USDT based IP licensing vault and BTX reward distribution DApp built on BNB Mainnet  
as part of the BeatSwap Licensing stack.

It manages user deposits, reserved balances, royalty backed consumption, and BTX reward claims  
using signed oracle messages and Merkle based distribution.

---

## Technology Stack

- Blockchain: BNB Mainnet (BNB Smart Chain Layer 1, EVM compatible)
- Smart Contracts: Solidity ^0.8.20 (OpenZeppelin ERC20 base)
- Tools: Hardhat + JavaScript
- Testing: Mocha + Chai
- CI: GitHub Actions

---

## Supported Network

- BNB Mainnet (Chain ID: 56)

You can also use the Hardhat local network for development and testing.

---

## Contract Information

| Network      | Contract Name       | Address         |
| ------------ | ------------------- | --------------- |
| BNB Mainnet | IPLicensingVault   | `TBD`           |

- Deposit Token: USDT compatible ERC20
- Reward Token: BTX compatible ERC20

---

## Core Features

- User vault with USDT deposits and per account deposit cap
- Time weighted reserved balance tracking for Vault Power
- Reserved and withdrawable balance split with precise accounting
- EIP 712 signed consumption updates for oracle style sync
- Cumulative royalty allocations with budget guard
- Epoch based BTX claims using Merkle proof
- Relayer based IDO participation using reserved funds
- Owner only excess USDT withdrawal with safety checks
- Lightweight pause switch for emergency situations

---

## System Architecture

```text
vault-to-earn/
├── bnb/
│   ├── contracts/
│   │   ├── IPLicensingVault.sol      # Core vault contract
│   │   └── MockERC20.sol             # Test ERC20 token
│   ├── scripts/
│   │   └── deploy-vault.js           # Deployment script
│   ├── test/
│   │   └── IPLicensingVault.basic.test.js
│   ├── artifacts/                    # Created on compile
│   └── cache/                        # Created on compile
├── .github/
│   └── workflows/
│       └── ci.yml                    # Compile and test on GitHub Actions
├── .env.example                      # Environment variable template
├── .gitignore
├── .prettierrc
├── .solhint.json
├── hardhat.config.js
├── package.json
├── LICENSE
└── README.md
