const { expect } = require("chai");
const { impersonate, deployPool, _E, _W, _R, addRiskModule,
        addEToken, amountFunction, getTransactionEvent, grantRole } = require("./test-utils");


describe("Test AaveHodlerVault contract - run at https://polygonscan.com/block/28165780", function() {
  let USDC;
  let pool;
  let priceRM;
  let PriceRiskModule;
  let EnsuroLPAaveHodlerVault;
  let usrUSDC;
  let usrWMATIC;
  let _A;
  let amWMATIC;
  let WMATIC;
  let variableDebtmUSDC;
  let exchange;
  let owner;
  let lp;
  let tokenInterestRate;

  const ADDRESSES = {
    usdc: "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174",
    wmatic: "0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270",
    weth: "0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619",
    ensuroTreasury: "0x913B9dff6D780cF4cda0b0321654D7261d5593d0",  // Random address
    etk: "0xCFfDcC8e99Aa22961704b9C7b67Ed08A66EA45Da",
    aave: "0xd05e3E715d945B59290df0ae8eF85c1BdB684744",  // AAVE Address Provider
    amWMATIC: "0x8dF3aad3a84da6b69A4DA8aeC3eA40d9091B2Ac4",
    aaveLendingPool: "0x8dFf5E27EA6b7AC08EbFdf9eB090F32ee9a30fcf",
    variableDebtmUSDC: "0x248960A9d75EdFa3de94F7193eae3161Eb349a12",
    oracle: "0x0229f777b0fab107f9591a41d5f02e4e98db6f2d",  // AAVE PriceOracle
    sushi: "0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506",  // Sushiswap router
    assetMgr: "0x09d9Dd252659a497F3525F257e204E7192beF132",
    usrUSDC: "0x4d97dcd97ec945f40cf65f87097ace5ea0476045", // Random account with lot of USDC
    usrWMATIC: "0x55FF76BFFC3Cdd9D5FdbBC2ece4528ECcE45047e", // Random account with log of WMATIC
  };

  const _BN = ethers.BigNumber.from;

  function _makeArray(n, initialValue) {
    const ret = new Array(n);
    for (i=0; i < n; i++) {
      ret[i] = initialValue;
    }
    return ret;
  }

  beforeEach(async () => {
    await network.provider.request({
      method: "hardhat_reset",
      params: [
        {
          forking: {
            jsonRpcUrl: process.env.ALCHEMY_URL,
            blockNumber: 28165780,
          },
        },
      ],
    });
    [owner, lp, cust] = await ethers.getSigners();

    USDC = await ethers.getContractAt("IERC20Metadata", ADDRESSES.usdc);
    WMATIC = await ethers.getContractAt("IERC20Metadata", ADDRESSES.wmatic);
    amWMATIC = await ethers.getContractAt("IERC20Metadata", ADDRESSES.amWMATIC);
    variableDebtmUSDC = await ethers.getContractAt("IERC20Metadata", ADDRESSES.variableDebtmUSDC);

    pool = await deployPool(hre, {
      currency: ADDRESSES.usdc, grantRoles: ["LEVEL1_ROLE", "LEVEL2_ROLE"],
      treasuryAddress: ADDRESSES.ensuroTreasury,
    });
    pool._A = _A = amountFunction(6);

    usrUSDC = await impersonate(ADDRESSES.usrUSDC, _E("10"));
    usrWMATIC = await impersonate(ADDRESSES.usrWMATIC, _E("10"));

    const Exchange = await ethers.getContractFactory("Exchange");
    exchange = await hre.upgrades.deployProxy(Exchange, [
      ADDRESSES.oracle,
      ADDRESSES.sushi,
      _E("0.02")
      ],
      {constructorArgs: [pool.address], kind: 'uups'}
    );
    await exchange.deployed();

    let poolConfig = await ethers.getContractAt("PolicyPoolConfig", await pool.config());
    await poolConfig.setExchange(exchange.address);

    PriceRiskModule = await ethers.getContractFactory("PriceRiskModule");
    priceRM = await addRiskModule(pool, PriceRiskModule, {
      extraConstructorArgs: [WMATIC.address, USDC.address, _W("0.01")],
    });

    grantRole(hre, priceRM, "PRICER_ROLE", owner.address);

    EnsuroLPAaveHodlerVault = await ethers.getContractFactory("EnsuroLPAaveHodlerVault", usrWMATIC);

    etk = await addEToken(pool, {});
    await USDC.connect(usrUSDC).transfer(lp.address, _A(11500));  // fill my lp account
    await USDC.connect(lp).approve(pool.address, _A(11500));
    await pool.connect(lp).deposit(etk.address, _A(10000));

    let TrustfulRiskModule = await ethers.getContractFactory("TrustfulRiskModule");
    tfRM = await addRiskModule(
      pool, TrustfulRiskModule,
      {scrInterestRate: 0.1333333, maxScrPerPolicy: 10000.0}
    );
    grantRole(hre, tfRM, "PRICER_ROLE", owner.address);

    const start = (await owner.provider.getBlock("latest")).timestamp;

    // But a new Policy to lock 9000 -> tokenInterestRate = 0.133333 * 0.9 = 12%
    await tfRM.connect(owner).newPolicy(
      _A(9900), _A(1500), _R(0.09090909), start + 3600 * 24 * 30, lp.address, 1234
    );

    tokenInterestRate = await etk.tokenInterestRate();
    expect(tokenInterestRate).to.closeTo(_R(0.12), _R(0.00001));
  });

  it("Should build an empty vault", async function() {
    const vault = await hre.upgrades.deployProxy(EnsuroLPAaveHodlerVault, [
      [_W("1.02"), _W("1.10"), _W("1.2"), _W("1.3"), exchange.address, 24 * 3600, 0],
      etk.address
    ], {
      kind: 'uups',
      unsafeAllow: ["delegatecall", "state-variable-immutable", "constructor"],
      constructorArgs: ["WETH EToken", "eWETH", priceRM.address, ADDRESSES.aave]
    });

    expect(await vault.totalAssets()).to.equal(0);
    expect(await vault.totalSupply()).to.equal(0);

  /*  await hre.network.provider.request(
      {method: "evm_increaseTime", params: [365 * 24 * 3600]}
    );

    await hre.network.provider.request(
      {method: "evm_mine", params: []}
    );

    await vault.connect(usrWMATIC).withdrawAll();

    const endBalance = await WMATIC.balanceOf(usrWMATIC.address);
    console.log(endBalance.sub(startBalance))

    // Around 2.51% interest
    expect(endBalance.sub(startBalance)).to.closeTo(_W(2.51), _W(0.01));*/
   });

  it("Should deposit and withdraw asset without checkpoint", async function() {
    const vault = await hre.upgrades.deployProxy(EnsuroLPAaveHodlerVault, [
      [_W("1.02"), _W("1.10"), _W("1.2"), _W("1.3"), exchange.address, 24 * 3600, 0],
      etk.address
    ], {
      kind: 'uups',
      unsafeAllow: ["delegatecall", "state-variable-immutable", "constructor"],
      constructorArgs: ["WMATIC EToken", "eWMATIC", priceRM.address, ADDRESSES.aave]
    });

    await WMATIC.connect(usrWMATIC).approve(vault.address, _W(100));

    const startBalance = await WMATIC.balanceOf(usrWMATIC.address);

    await expect(() => vault.connect(usrWMATIC).deposit(_W(100), usrWMATIC.address)).to.changeTokenBalances(
      WMATIC, [usrWMATIC, vault, amWMATIC], [_W(-100), _W(0), _W(100)]
    );

    expect(await vault.totalAssets()).to.equal(_W(100));
    expect(await vault.totalSupply()).to.equal(_W(100));

    expect(await amWMATIC.balanceOf(vault.address)).to.closeTo(_W(100), _W(0.001));
    expect(await variableDebtmUSDC.balanceOf(vault.address)).to.equal(0);  // Doesn't borrow

    let totalAssets = await vault.totalAssets();

    await expect(() => vault.connect(usrWMATIC).withdraw(
      totalAssets, usrWMATIC.address, usrWMATIC.address
    )).to.changeTokenBalances(
      WMATIC, [usrWMATIC, vault, amWMATIC], [totalAssets, 0, totalAssets.mul(_BN(-1))]
    )

    expect(await vault.totalAssets()).to.closeTo(_W(0), _W(0.0001));
    expect(await vault.totalSupply()).to.closeTo(_W(0), _W(0.001));
    expect(await WMATIC.balanceOf(usrWMATIC.address)).to.be.closeTo(startBalance, _W(0.001));
  });

  it("Should deposit and withdraw asset invest checkpoint policy reduced", async function() {
    const vault = await hre.upgrades.deployProxy(EnsuroLPAaveHodlerVault, [
      [_W("1.02"), _W("1.10"), _W("1.2"), _W("1.3"), exchange.address, 24 * 3600, 0],
      etk.address
    ], {
      kind: 'uups',
      unsafeAllow: ["delegatecall", "state-variable-immutable", "constructor"],
      constructorArgs: ["WMATIC EToken", "eWMATIC", priceRM.address, ADDRESSES.aave]
    });

    const wmaticPrice = await exchange.convert(ADDRESSES.wmatic, ADDRESSES.usdc, _W(1));
    expect(wmaticPrice).to.equal(_A(0.913779));

    await WMATIC.connect(usrWMATIC).approve(vault.address, _W(100));

    await expect(() => vault.connect(usrWMATIC).deposit(_W(100), usrWMATIC.address)).to.changeTokenBalances(
      WMATIC, [usrWMATIC, vault, amWMATIC], [_W(-100), _W(0), _W(100)]
    );

    expect(await vault.totalAssets()).to.equal(_W(100));
    expect(await vault.totalSupply()).to.equal(_W(100));

    expect(await amWMATIC.balanceOf(vault.address)).to.closeTo(_W(100), _W(0.001));
    expect(await variableDebtmUSDC.balanceOf(vault.address)).to.equal(0);  // Doesn't borrow

    let expectedBorrow = _A(0.913779 * 100 * 0.7 / 1.30);
    let tx = await vault.checkpoint();
    let receipt = await tx.wait();
    expect(await variableDebtmUSDC.balanceOf(vault.address)).to.be.closeTo(expectedBorrow, _A(0.01));

    // Probability 5% --> natural premium is bigger than expectedYield --> premium == expectedYield
    const priceSlots = await priceRM.PRICE_SLOTS();
    const cdf = _makeArray(priceSlots, _R(0.05));
    await priceRM.connect(owner).setCDF(24, cdf);

    const expectedYield = await vault.expectedYield(3600 * 24);
    expect(expectedYield).to.equal(10840);  // ~(0.913779 * 100 * 0.7 / 1.30) * 0.07 * (1/365)

    tx = await vault.insure(false);
    receipt = await tx.wait();
    const PolicyPool = await ethers.getContractFactory("PolicyPool");
    const newPolicyEvt = getTransactionEvent(PolicyPool.interface, receipt, "NewPolicy");
    expect(newPolicyEvt.args.policy.premium).to.be.equal(expectedYield);
    expect(newPolicyEvt.args.policy.payout).to.be.equal(215676);
    expect(newPolicyEvt.args.policy.purePremium).to.be.closeTo(
      newPolicyEvt.args.policy.payout.div(20), _A(0.001)
    ); // 5%
  });

  it("Should deposit and withdraw asset invest checkpoint policy standard", async function() {
    const vault = await hre.upgrades.deployProxy(EnsuroLPAaveHodlerVault, [
      [_W("1.02"), _W("1.05"), _W("1.2"), _W("1.3"), exchange.address, 24 * 3600, 0],
      etk.address
    ], {
      kind: 'uups',
      unsafeAllow: ["delegatecall", "state-variable-immutable", "constructor"],
      constructorArgs: ["WMATIC EToken", "eWMATIC", priceRM.address, ADDRESSES.aave]
    });

    const wmaticPrice = await exchange.convert(ADDRESSES.wmatic, ADDRESSES.usdc, _W(1));
    expect(wmaticPrice).to.equal(_A(0.913779));

    await WMATIC.connect(usrWMATIC).approve(vault.address, _W(100));

    await expect(() => vault.connect(usrWMATIC).deposit(_W(100), usrWMATIC.address)).to.changeTokenBalances(
      WMATIC, [usrWMATIC, vault, amWMATIC], [_W(-100), _W(0), _W(100)]
    );

    expect(await vault.totalAssets()).to.equal(_W(100));
    expect(await vault.totalSupply()).to.equal(_W(100));

    expect(await amWMATIC.balanceOf(vault.address)).to.closeTo(_W(100), _W(0.001));
    expect(await variableDebtmUSDC.balanceOf(vault.address)).to.equal(0);  // Doesn't borrow

    let totalAssets = await vault.totalAssets();

    let expectedBorrow = _A(0.913779 * 100 * 0.7 / 1.30);
    let tx = await vault.checkpoint();
    let receipt = await tx.wait();
    expect(await variableDebtmUSDC.balanceOf(vault.address)).to.be.closeTo(expectedBorrow, _A(0.01));


    // Probability 0.05% --> cheap policy
    const priceSlots = await priceRM.PRICE_SLOTS();
    const cdf = _makeArray(priceSlots, _R(0.0005));
    await priceRM.connect(owner).setCDF(24, cdf);

    const expectedPayout = _A(0.913779 * (1.02/1.3) * 100 * (1.05/1.02 - 1));

    tx = await vault.insure(false);
    receipt = await tx.wait();
    const PolicyPool = await ethers.getContractFactory("PolicyPool");
    const newPolicyEvt = getTransactionEvent(PolicyPool.interface, receipt, "NewPolicy");
    expect(newPolicyEvt.args.policy.id).to.be.equal(await vault.activePolicyId());
    expect(newPolicyEvt.args.policy.expiration).to.be.equal(await vault.activePolicyExpiration());
    expect(newPolicyEvt.args.policy.premium).to.be.equal(1631);
    expect(newPolicyEvt.args.policy.payout).to.be.closeTo(expectedPayout, _A(0.001));
    expect(newPolicyEvt.args.policy.purePremium).to.be.closeTo(
      _A(0.913779 * (1.02/1.3) * 100 * (1.05/1.02 - 1) * 0.0005), _A(0.001)
    );

    expect((await vault.totalAssets()).lt(totalAssets)).to.be.true;

    // After 24 hours, new policy expires
    await network.provider.send("evm_increaseTime", [3600 * 24])
    await network.provider.send("evm_mine") // this one will have 02:00 PM as its timestamp
    tx = await pool.expirePolicy(newPolicyEvt.args.policy);
    receipt = await tx.wait();
    const renewPolicyEvt = getTransactionEvent(PolicyPool.interface, receipt, "NewPolicy");
    expect(newPolicyEvt.args.policy.id).not.to.be.equal(renewPolicyEvt.args.policy.id);
    expect(renewPolicyEvt.args.policy.id).to.be.equal(await vault.activePolicyId());
    expect(renewPolicyEvt.args.policy.premium).to.be.closeTo(_A(0.001631), _A(0.00001));
    expect(renewPolicyEvt.args.policy.payout).to.be.closeTo(expectedPayout, _A(0.001));
    expect(renewPolicyEvt.args.policy.purePremium).to.be.closeTo(
      _A(0.913779 * (1.02/1.3) * 100 * (1.05/1.02 - 1) * 0.0005), _A(0.001)
    );
  });
});
