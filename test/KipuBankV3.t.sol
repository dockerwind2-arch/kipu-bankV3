// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20 <0.9.0;

import "forge-std/Test.sol";
import "../src/KipuBankV3.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/* ------------------------- Mocks mínimos ------------------------- */

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {
        _mint(msg.sender, 1_000_000 * 10 ** 6);
    }
    function decimals() public pure override returns (uint8) { return 6; }
}

contract MockAggregator {
    int256 private price;
    constructor(int256 _price) { price = _price; }
    function latestRoundData()
        external view
        returns (uint80, int256 answer, uint256, uint256, uint80)
    { return (0, price, 0, 0, 0); }
}

// Router mock que sólo expone WETH() para el constructor
contract MockRouter {
    address public weth;
    constructor(address _weth) { weth = _weth; }
    function WETH() external view returns (address) { return weth; }
}

// Factory mock que siempre “tiene” par (para tests simples)
contract MockFactory {
    function getPair(address, address) external pure returns (address) {
        return address(0x2222);
    }
}

/* --------------------------- Tests ------------------------------- */

contract KipuBankV3Test is Test {
    KipuBankV3 public bank;
    MockUSDC public usdc;
    MockAggregator public mockFeed;
    MockRouter public mockRouter;
    MockFactory public mockFactory;

    address public admin = address(this);

    function setUp() public {
        // Deploy mocks
        usdc      = new MockUSDC();
        mockFeed  = new MockAggregator(2000e8);         // 2000 USD por ETH
        mockRouter= new MockRouter(address(0x1111));     // WETH ficticia != 0
        mockFactory = new MockFactory();

        // Aserciones de sanidad: si algo es 0, falla aquí con mensaje claro
        assertTrue(address(usdc) != address(0), "USDC es address(0)");
        assertTrue(address(mockRouter) != address(0), "Router es address(0)");
        assertTrue(address(mockFactory) != address(0), "Factory es address(0)");

        // Desplegar el banco
        bank = new KipuBankV3(
            1_000e6,        // withdrawLimit (1,000 USDC)
            0,              // bankCap (legacy)
            0,              // bankCapUSD (legacy)
            1_000_000e6,    // bankCapUSDC
            address(mockFeed),
            address(mockRouter),
            address(mockFactory),
            address(usdc)
        );
    }

    function testOwnerIsAdmin() public {
        assertTrue(bank.hasRole(bank.ADMIN_ROLE(), admin));
    }

    function testDepositUSDC() public {
        uint256 amount = 100e6;
        usdc.approve(address(bank), amount);
        bank.depositUSDC(amount);
        assertEq(bank.getVaultBalance(admin, address(usdc)), amount);
    }

    function testWithdrawUSDC() public {
        uint256 amount = 100e6;
        usdc.approve(address(bank), amount);
        bank.depositUSDC(amount);
        bank.withdrawUSDC(amount);
        assertEq(bank.getVaultBalance(admin, address(usdc)), 0);
    }

    function testExpectRevert_WhenWithdrawWithoutFunds() public {
        vm.expectRevert(); // ErrorFondosInsuficientes()
        bank.withdrawUSDC(1e6);
    }
}


