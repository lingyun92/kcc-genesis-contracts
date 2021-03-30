# kcc-genesis-contracts

KuCoin Community Chain Genesis contracts based on the huobi-eco-contracts.

## Contracts(PoS related)

- Validators
- Proposal
- Punish

## Prepare

Install dependency:

```bash
npm install
```

## unit test

Generate test contract files:

```bash
node generate-mock-contracts.js
```

Start ganache:

```bash
ganache-cli -e 20000000000 -a 100 -l 8000000 -g 0
```

Test:

```bash
truffle compile
truffle migrate
truffle test
```
