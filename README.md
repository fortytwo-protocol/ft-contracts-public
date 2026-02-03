# FortyTwo Contracts

This repository contains the core smart contracts for [FortyTwo](https://42.space). An onchain, curve-agnostic platform for event outcomes that prices via bonding curves and settles parimutuelly.

## Deployed Contracts
FortyTwo is deployed on Bscscan. All deployed contracts can be found in the [`deployments`](/deployments) directory.

## Audits
FortyTwo has been audited by 3 auditors. Audit reports are available in the [`audits`](/audits) directory

## Usage

### Setup
[Foundry](https://getfoundry.sh/introduction/installation/) - Core dev framework
```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

Lcov - Coverage reports
```bash
brew install lcov
```

### Start
```bash
# clone repo
git clone git@github.com:fortytwo-protocol/ft-contracts-public.git
cd ft-contracts-public

# setup deps
forge install
cp .env.example .env

# build
forge build
forge test
forge coverage --report lcov --report summary
```