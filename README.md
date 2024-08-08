![Banner](https://i.imgur.com/QhKQ20H.png)


## Tutorial Video

[How to Create Position](https://www.youtube.com/watch?v=d6mH4jSDhds)

## Introduction

Satoshi Protocol is a revolutionary "universal" stablecoin protocol backed by Bitcoin. It allows users to deposit assets as collateral to mint the stablecoin $SAT on both Bitcoin mainnet and multiple L2s.

## Build
```
forge build
```

## Test
```
forge test
```

## Future Plan

### Universal Stablecoin (Omni Network)
Our plan includes a strategic partnership with Omni Network to evolve the Satoshi Protocol into a universal rollup stablecoin. We aim to deploy Satoshi Protocol across multiple blockchain networks by leveraging Omni's advanced infrastructure. This integration will enable users to deposit collateral on any source network and mint the stablecoin on various destination networks, effectively aggregating liquidity from the entire blockchain ecosystem.

**Omni Network** Serves as a chain abstraction platform that grants developers access to liquidity and users from the Ethereum ecosystem. As the execution layer for $SAT, Omni will handle all protocol mechanisms, including minting, liquidation, and redemption.

**How It Works:**
- Collateralized assets will be locked in the Satoshi Omni Router/Vault on the source network.
- Transactions will be initiated from the source network, where the Satoshi Omni Router interacts with Omni's Portal contract via xcall.
- The Portal contract will then transmit the relevant information to the Satoshi XApp on the Omni Network via XMsg for further logical execution.

This integration will address fragmentation and increase the utility of the Satoshi Protocol by supporting a wide range of collateral types from multiple networks.

![Omni Architecture](https://i.imgur.com/h5pDtcs.png)

### Bitcoin Mainnet integration
As part of our roadmap, we plan to integrate with Babylon, a Bitcoin staking protocol designed to unlock the potential of 21 million dormant Bitcoins. This partnership will allow users to stake their native $BTC on the Bitcoin Mainnet and mint stablecoins on any blockchain network, fully utilizing the potential of $BTC.

Babylon will integrate Bitcoin into PoS protocols, enhancing system security, and operational efficiency, and mitigating centralization risks. Babylon’s Layer 1 chain, developed on the Cosmos SDK, will be maintained through Bitcoin staking, supporting IBC ecosystem interoperability for seamless asset exchanges. Bitcoin Timestamping will further enhance PoS chain security through records on the Bitcoin Mainnet.

**Integration Overview:**
Through this integration, users can unlock the potential of their Bitcoin assets with just one click. By staking $BTC on the Bitcoin Mainnet, users can convert their assets into LST protocol tokens. These tokenized assets will be integrated into the Satoshi Protocol, allowing users to leverage $SAT on their chosen destination chains. This will significantly enhance the utility of previously idle $BTC, transforming it into highly efficient and liquid assets that can be utilized across all DeFi protocols.

This integration will offer unparalleled simplicity and convenience. Users will enhance blockchain network security through Babylon, earn rewards, and engage with Babylon’s ecosystem in a few simple steps. Most importantly, users will be able to leverage their staked $BTC as collateral within the Satoshi Protocol to mint $SAT stablecoins. These stablecoins will represent leveraged liquidity, which can be reinvested in other DeFi protocols, maximizing returns.

![Bitcoin Mainnet integration](https://i.imgur.com/SMjWZUF.png)

### Bitcoin Mainnet Runes Standard Stablecoin
Recognizing the absence of a robust CDP stablecoin protocol on the Bitcoin Mainnet, we plan to introduce a native collateral mechanism utilizing the Runes standard for seamless circulation. This will enable transactions on Bitcoin to be priced in stable US dollars, significantly expanding DeFi use cases.

Our token will support multiple standards, including RUNES, ERC20, and BRC20, allowing for seamless integration across various protocols. Additionally, we will develop a multi-standard cross-chain bridge, facilitating easy transitions between different standards and ecosystems. This approach will ensure that users can engage in stable, USD-denominated transactions on the Bitcoin network while leveraging the full potential of DeFi.

By implementing these innovations, the Satoshi Protocol will enhance the utility and adoption of Bitcoin, fostering a more integrated and efficient blockchain ecosystem.

![Bitcoin Mainnet RUNES stablecoin](https://i.imgur.com/jWZ8eIj.png)
