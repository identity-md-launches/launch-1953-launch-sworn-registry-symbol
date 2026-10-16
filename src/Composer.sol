// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Spec} from "./Types.sol";
import {IWhitelistCurator} from "./interfaces/IWhitelistCurator.sol";
import {IIDMD} from "./interfaces/IIDMD.sol";

interface ICatalogRegistry {
    function hasTrait(address wallet, uint16 traitId) external view returns (bool);
}

/// @notice Composes the five question templates of TEMPLATES.md into the Intake request body (sorted
///         keys, two-space indent, byte-exact against `templates/fixtures/`) and into the plane's
///         canonical question document (RFC 8785: sorted keys, no whitespace) whose keccak is the
///         attestation's `questionHash` (INTEGRATION.md section 4, check 7).
/// @dev    A separately deployed contract (no arguments, no storage, no immutables): the composed text
///         does not fit the registry's EIP-170 budget. All template text is ASCII and carries no `"` or `\`;
///         spec strings are charset-checked at registration, so no JSON escaping is ever needed here.
contract Composer {
    string public constant DEPOSITED =
        "event Deposited(address indexed contributor, uint256 indexed hour, uint256 amount, uint256 creditedDelta, uint256 weightAdded, uint256 newWeight, uint256 txCount, uint256 hourTotal, uint256 earlyBps)";
    string public constant FIRST_DEPOSIT =
        "event FirstDeposit(address indexed contributor, uint256 indexed index, uint256 timestamp)";
    string public constant HOUR_SAVED =
        "event HourSaved(address indexed savior, uint256 indexed hour, uint256 hourTotal)";

    string internal constant DEF_WINDOW = "The pinned window is the whole evidence; events outside it do not count.";
    string internal constant DEF_T1_METHOD =
        "eth_getLogs on the contract with topic0 = the event's signature hash and the indexed argument(s) as topics, over exactly the pinned window; or the equivalent explorer log query. Count matching logs; do not deduplicate by transaction. Block numbers are hex.";
    string internal constant DEF_T2_METHOD =
        "eth_getLogs on the contract with topic0 = the event's signature hash and the indexed argument(s) as topics, over exactly the pinned window; or the equivalent explorer log query. Sum the named argument of matching logs; do not deduplicate by transaction. Block numbers are hex.";
    string internal constant DEF_T2_UNITS = "Raw integer units of the argument as emitted, e.g. wei for an ETH amount.";

    /// @notice The hash of the Curator deploy block, the only block hash a body ever carries (trait 1301).
    bytes32 internal constant B_DEPLOY_HASH = 0x43ac0aadac9b134a5e4555d28323431664fd77d74cd6a28cb4ca65e34ba72256;

    /// @notice The WhitelistCurator on Ethereum mainnet (CATALOG.md section 3, TEMPLATES.md). Every catalog
    ///         question is about mainnet, so it names this contract on every consumer chain; the registry's
    ///         `curator` argument is the deployment chain's Curator and serves the direct reads only.
    address public constant MAINNET_CURATOR = 0xcB0b0531e86A9aC36Fa865cA8e3dbccF047FDA91;

    /// @dev First post-merge mainnet block and its timestamp (slot 4,700,013). Mainnet has mined at most one
    ///      block per 12-second slot since, so `MERGE_BLOCK + (now - MERGE_TIME) / 12` bounds its height from
    ///      above on any chain whose clock is the consumer's `block.timestamp`.
    uint256 internal constant MERGE_BLOCK = 15_537_395;
    uint256 internal constant MERGE_TIME = 1_663_224_191;
    uint256 internal constant SLOT_SECONDS = 12;

    uint16 internal constant CHAIN_PANEL = 5;
    uint16 internal constant CHAIN_QUORUM = 3;
    uint16 internal constant PANEL_PANEL = 11;
    uint16 internal constant PANEL_QUORUM = 7;
    uint256 internal constant VALID_FOR_SECONDS = 2_592_000;
    uint256 internal constant MAX_QUESTION = 1000;
    uint256 internal constant MAX_DEFINITION = 512;

    /// @dev A composed question: text, sorted definition keys and values, and the fixed fields.
    struct Question {
        string question;
        string[] keys;
        string[] values;
        string answerType; // "uint256", "address[]" or "bool"
        bool panel; // evidence: panel (T5) or chain
        uint256 head; // T3 only, else 0
        uint64 fromBlock;
        uint64 toBlock;
    }

    error QuestionTooLong(uint256 length);
    error DefinitionTooLong(uint256 length);

    // ------------------------------------------------------------------ the catalog as specs

    uint64 internal constant B_DEPLOY = 0x189378e;
    uint64 internal constant B_FIRST1000 = 0x1893b91;
    uint64 internal constant B_H24 = 0x1895395;
    uint64 internal constant B_END = 0x18984a4;

    error NotACatalogOracleTrait(uint16 traitId);

    /// @notice A catalog oracle trait (701 to 1301) expressed as a Spec (CATALOG.md section 3).
    /// @dev The target is always the mainnet Curator: the question is about mainnet whatever chain the
    ///      registry runs on. The second argument (the registry's Curator) is kept for the ABI and unused.
    function catalogSpec(uint16 traitId, address) external pure returns (Spec memory s) {
        s.target = MAINNET_CURATOR;
        s.threshold = 1;
        s.fromBlock = B_DEPLOY;
        s.toBlock = B_END;
        if (traitId == 701) {
            s.kind = 1;
            s.item = DEPOSITED;
            s.arg = "contributor";
            s.fromBlock = B_H24;
            s.name = "Uptime";
        } else if (traitId == 801 || traitId == 901) {
            s.kind = 1;
            s.item = DEPOSITED;
            s.arg = "contributor";
            s.fixedArg = "hour";
            s.fixedVal = traitId == 801 ? 64 : 65;
            s.name = traitId == 801 ? "Holdout" : "Final Token";
        } else if (traitId == 1001) {
            s.kind = 1;
            s.item = HOUR_SAVED;
            s.arg = "savior";
            s.name = "Hotfix";
        } else if (traitId >= 1101 && traitId <= 1104) {
            s.kind = 1;
            s.item = FIRST_DEPOSIT;
            s.arg = "contributor";
            s.fixedArg = "index";
            s.fixedVal = traitId == 1101 ? 1 : traitId == 1102 ? 1000 : traitId == 1103 ? 10000 : 19522;
            s.name = traitId == 1101
                ? "PID #1"
                : traitId == 1102 ? "PID #1000" : traitId == 1103 ? "PID #10000" : "PID #19522";
        } else if (traitId == 1105) {
            s.kind = 1;
            s.item = FIRST_DEPOSIT;
            s.arg = "contributor";
            s.toBlock = B_FIRST1000;
            s.name = "First thousand";
        } else if (traitId == 1201) {
            s.kind = 3;
            s.item = DEPOSITED;
            s.arg = "contributor";
            s.sumArg = "weightAdded";
            s.threshold = 32;
            s.name = "Top Weights";
        } else if (traitId == 1301) {
            s.kind = 5;
            s.target = address(0);
            s.threshold = 20;
            s.toBlock = B_DEPLOY;
            s.name = "Pretrained";
        } else {
            revert NotACatalogOracleTrait(traitId);
        }
    }

    /// @notice The direct-read predicates used by Registry.hasTrait and catalog enumeration.
    function hasDirectTrait(address wallet, uint16 traitId, IWhitelistCurator curator, IIDMD idmd)
        external
        view
        returns (bool)
    {
        if (wallet == address(0)) return false;
        if (traitId == 101 || traitId == 201 || traitId == 202) {
            (uint256 hour, bool joined) = curator.firstHourOf(wallet);
            if (!joined) return false;
            if (traitId == 101) return true;
            return traitId == 201 ? hour <= 1 : hour == 0;
        }
        if (traitId >= 301 && traitId <= 303) {
            uint256 n = curator.txCountOf(wallet);
            return n >= (traitId == 301 ? 3 : traitId == 302 ? 5 : 10);
        }
        if (traitId >= 401 && traitId <= 404) {
            uint256 w = curator.contributedBy(wallet);
            return w >= (traitId == 401 ? 1e18 : traitId == 402 ? 1e19 : traitId == 403 ? 1e20 : 8e20);
        }
        if (traitId >= 501 && traitId <= 503) {
            uint256 p = curator.pointsOf(wallet);
            return p >= (traitId == 501 ? 1000 : traitId == 502 ? 3162 : 10000);
        }
        if (traitId == 601) return idmd.balanceOf(wallet) >= 1;
        return false;
    }

    /// @notice Enumerates all true catalog ids in ascending order; community specs are excluded.
    /// @dev The registry supplies itself as the read source. Kept here for its EIP-170 headroom.
    function traitsOf(address registry, address wallet) external view returns (uint16[] memory ids) {
        uint16[25] memory all = [
            101,
            201,
            202,
            301,
            302,
            303,
            401,
            402,
            403,
            404,
            501,
            502,
            503,
            601,
            701,
            801,
            901,
            1001,
            1101,
            1102,
            1103,
            1104,
            1105,
            1201,
            1301
        ];
        uint16[] memory tmp = new uint16[](25);
        uint256 n;
        for (uint256 i; i < 25; ++i) {
            if (ICatalogRegistry(registry).hasTrait(wallet, all[i])) tmp[n++] = all[i];
        }
        ids = new uint16[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = tmp[i];
        }
    }

    // ------------------------------------------------------------------ names and spec guards

    error UnknownTrait(uint16 traitId);
    error BadSpec(string field);

    /// @notice The name table of CATALOG.md section 7 (final names, 2026-10-16) for the 25 catalog ids.
    function traitName(uint16 traitId) external pure returns (string memory) {
        if (traitId == 101) return "Spawned";
        if (traitId == 201) return "Zero-Shot, hour <= 1";
        if (traitId == 202) return "Zero-Shot, hour 0";
        if (traitId == 301) return "Hopper >= 3";
        if (traitId == 302) return "Hopper >= 5";
        if (traitId == 303) return "Hopper >= 10";
        if (traitId == 401) return "Bullfrog >= 1 ETH";
        if (traitId == 402) return "Bullfrog >= 10 ETH";
        if (traitId == 403) return "Bullfrog >= 100 ETH";
        if (traitId == 404) return "Bullfrog >= 800 ETH";
        if (traitId == 501) return "Benchmarked >= 1000";
        if (traitId == 502) return "Benchmarked >= 3162";
        if (traitId == 503) return "Benchmarked >= 10000";
        if (traitId == 601) return "Armed";
        if (traitId == 701) return "Uptime";
        if (traitId == 801) return "Holdout";
        if (traitId == 901) return "Final Token";
        if (traitId == 1001) return "Hotfix";
        if (traitId == 1101) return "PID #1";
        if (traitId == 1102) return "PID #1000";
        if (traitId == 1103) return "PID #10000";
        if (traitId == 1104) return "PID #19522";
        if (traitId == 1105) return "First thousand";
        if (traitId == 1201) return "Top Weights";
        if (traitId == 1301) return "Pretrained";
        revert UnknownTrait(traitId);
    }

    /// @notice The guards of CATALOG.md section 5; reverts `BadSpec(field)` on the first failing field.
    /// @param blockNumber The consumer chain's `block.number`. A window is a range of mainnet blocks, so it is
    ///        bounded by the mainnet height: `blockNumber` itself on chain 1, else the slot-clock upper bound
    ///        `mainnetHeightBound()` (a Sepolia or Base height says nothing about mainnet).
    function validateSpec(Spec calldata s, uint256 blockNumber) external view {
        if (block.chainid != 1) blockNumber = mainnetHeightBound();
        if (s.kind < 1 || s.kind > 5) revert BadSpec("kind");
        bytes memory item = bytes(s.item);
        if (s.kind == 5) {
            if (s.target != address(0)) revert BadSpec("target");
            if (item.length != 0) revert BadSpec("item");
        } else {
            if (s.target == address(0)) revert BadSpec("target");
            if (item.length > 256) revert BadSpec("item");
            bytes memory prefix = s.kind == 4 ? bytes("function ") : bytes("event ");
            if (item.length <= prefix.length) revert BadSpec("item");
            for (uint256 i; i < prefix.length; ++i) {
                if (item[i] != prefix[i]) revert BadSpec("item");
            }
            if (!_charset(item, true)) revert BadSpec("item");
        }
        bytes memory arg = bytes(s.arg);
        if (s.kind <= 3) {
            if (arg.length == 0) revert BadSpec("arg");
        } else if (arg.length != 0) {
            revert BadSpec("arg");
        }
        if (arg.length > 32 || !_charset(arg, false)) revert BadSpec("arg");
        bytes memory fixedArg = bytes(s.fixedArg);
        if (fixedArg.length > 32 || !_charset(fixedArg, false)) revert BadSpec("fixedArg");
        if (s.kind > 2 && (fixedArg.length != 0 || s.fixedVal != 0)) revert BadSpec("fixedArg");
        if (s.kind <= 2 && fixedArg.length == 0 && s.fixedVal != 0) revert BadSpec("fixedVal");
        bytes memory sumArg = bytes(s.sumArg);
        if (s.kind == 2 || s.kind == 3) {
            if (sumArg.length == 0 || sumArg.length > 32 || !_charset(sumArg, false)) revert BadSpec("sumArg");
        } else if (sumArg.length != 0) {
            revert BadSpec("sumArg");
        }
        if (s.kind == 4) {
            if (s.op < 1 || s.op > 5) revert BadSpec("op");
        } else if (s.op != 0) {
            revert BadSpec("op");
        }
        if (s.kind == 3) {
            if (s.threshold < 1 || s.threshold > 32) revert BadSpec("threshold");
        } else if (s.threshold < 1) {
            revert BadSpec("threshold");
        }
        if (s.kind == 5) {
            if (s.fromBlock != s.toBlock || uint256(s.toBlock) + 7200 > blockNumber) revert BadSpec("window");
        } else {
            if (s.toBlock < s.fromBlock || uint256(s.toBlock) - s.fromBlock + 1 < 7200 || s.toBlock >= blockNumber) {
                revert BadSpec("window");
            }
        }
        bytes memory name = bytes(s.name);
        if (name.length < 1 || name.length > 32) revert BadSpec("name");
        for (uint256 i; i < name.length; ++i) {
            bytes1 ch = name[i];
            bool ok = (ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z") || (ch >= "0" && ch <= "9") || ch == " "
                || ch == "." || ch == "-";
            if (!ok) revert BadSpec("name");
        }
    }

    /// @notice The largest mainnet height possible at the consumer chain's `block.timestamp`: one block per
    ///         12-second slot since the merge. Exact only in the sense of never being below the true height.
    function mainnetHeightBound() public view returns (uint256) {
        if (block.timestamp <= MERGE_TIME) return MERGE_BLOCK;
        return MERGE_BLOCK + (block.timestamp - MERGE_TIME) / SLOT_SECONDS;
    }

    /// @dev `[A-Za-z0-9_]`, plus ` ,()[]` when `item` is true.
    function _charset(bytes memory b, bool item) internal pure returns (bool) {
        for (uint256 i; i < b.length; ++i) {
            bytes1 ch = b[i];
            bool ok = (ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z") || (ch >= "0" && ch <= "9") || ch == "_";
            if (!ok && item) ok = ch == " " || ch == "," || ch == "(" || ch == ")" || ch == "[" || ch == "]";
            if (!ok) return false;
        }
        return true;
    }

    // ------------------------------------------------------------------ public shape

    /// @notice The answerType code of a kind: 3 uint256 (T1, T2), 4 address[] (T3), 0 bool (T4, T5).
    function answerTypeOf(uint8 kind) public pure returns (uint8) {
        if (kind == 1 || kind == 2) return 3;
        if (kind == 3) return 4;
        return 0;
    }

    function panelOf(uint8 kind) public pure returns (uint16 panelSize, uint16 quorum) {
        return kind == 5 ? (PANEL_PANEL, PANEL_QUORUM) : (CHAIN_PANEL, CHAIN_QUORUM);
    }

    /// @notice Composes the body and the plane's `questionHash` for a spec and a claimant.
    /// @param catalogNonce true for trait 1301, whose T5 parenthesis names the mainnet Curator's deploy block.
    /// @dev The fifth argument (the registry's Curator) is kept for the ABI and unused: the parenthesis names
    ///      `MAINNET_CURATOR`, the contract the question is about, on every consumer chain.
    function compose(Spec memory s, address claimant, address consumer, bool catalogNonce, address)
        external
        view
        returns (bytes memory body, bytes32 questionHash)
    {
        Question memory q = question(s, claimant, catalogNonce);
        if (bytes(q.question).length > MAX_QUESTION) revert QuestionTooLong(bytes(q.question).length);
        for (uint256 i; i < q.values.length; ++i) {
            if (bytes(q.values[i]).length > MAX_DEFINITION) revert DefinitionTooLong(bytes(q.values[i]).length);
        }
        body = encodeBody(q, consumer);
        questionHash = keccak256(canonical(q));
    }

    // ------------------------------------------------------------------ the five templates

    function question(Spec memory s, address claimant, bool catalogNonce) internal pure returns (Question memory q) {
        string memory a = Strings.toHexString(claimant);
        string memory c = Strings.toHexString(s.target);
        string memory from = hexMin(s.fromBlock);
        string memory to = hexMin(s.toBlock);
        string memory n = Strings.toString(s.threshold);
        q.fromBlock = s.fromBlock;
        q.toBlock = s.toBlock;
        if (s.kind == 1 || s.kind == 2) {
            q.answerType = "uint256";
            string memory filter = bytes(s.fixedArg).length == 0
                ? ""
                : string.concat(" and whose indexed ", s.fixedArg, " argument equals ", Strings.toString(s.fixedVal));
            string memory head = string.concat(
                "Within the request's pinned block window (fromBlock ",
                from,
                " to toBlock ",
                to,
                ", both inclusive) on Ethereum mainnet, "
            );
            if (s.kind == 1) {
                q.question = string.concat(
                    head,
                    "count the `",
                    s.item,
                    "` events emitted by the contract ",
                    c,
                    " whose indexed ",
                    s.arg,
                    " argument equals ",
                    a,
                    filter,
                    ". Answer the count as one integer; answer 0 if no such event exists."
                );
                q.keys = new string[](2);
                q.values = new string[](2);
                q.keys[0] = "method";
                q.values[0] = DEF_T1_METHOD;
                q.keys[1] = "window";
                q.values[1] = DEF_WINDOW;
            } else {
                q.question = string.concat(
                    head,
                    string.concat(
                        "sum the ", s.sumArg, " argument of the `", s.item, "` events emitted by the contract "
                    ),
                    c,
                    " whose indexed ",
                    s.arg,
                    " argument equals ",
                    a,
                    filter,
                    ". Answer the sum as one integer in the argument's raw units (no decimals applied); answer 0 if no such event exists."
                );
                q.keys = new string[](3);
                q.values = new string[](3);
                q.keys[0] = "method";
                q.values[0] = DEF_T2_METHOD;
                q.keys[1] = "units";
                q.values[1] = DEF_T2_UNITS;
                q.keys[2] = "window";
                q.values[2] = DEF_WINDOW;
            }
        } else if (s.kind == 3) {
            q.answerType = "address[]";
            q.head = s.threshold;
            q.question = string.concat(
                "Within the request's pinned block window (fromBlock ",
                from,
                " to toBlock ",
                to,
                ", both inclusive) on Ethereum mainnet, sum the ",
                s.sumArg,
                " argument of the `",
                s.item,
                string.concat(
                    "` events emitted by the contract ",
                    c,
                    " grouped by the indexed ",
                    s.arg,
                    " argument. Return the ",
                    n,
                    " keys with the largest sums, descending by sum, ties by address ascending (lowercase hex)."
                )
            );
            q.keys = new string[](1);
            q.values = new string[](1);
            q.keys[0] = "method";
            q.values[0] = string.concat(
                "eth_getLogs over exactly the pinned window, group by the indexed argument, sum in raw units, sort as stated; include a few positions beyond ",
                n,
                "; agreement is on the first ",
                n,
                "."
            );
        } else if (s.kind == 4) {
            q.answerType = "bool";
            string memory op = opText(s.op);
            q.question = string.concat(
                "At the last block of the request's pinned window (toBlock ",
                to,
                ") on Ethereum mainnet, does the view function `",
                s.item,
                "` of the contract ",
                c,
                " return a value ",
                op,
                " ",
                n,
                string.concat(" for the address ", a, "? Answer true or false.")
            );
            q.keys = new string[](1);
            q.values = new string[](1);
            q.keys[0] = "method";
            q.values[0] = string.concat(
                "One eth_call of the function with ",
                a,
                " as the argument at block ",
                to,
                " (hex, not 'latest') on an endpoint with historical state; compare the raw integer return value with ",
                n,
                " using ",
                op,
                ". A null, pruned or 'latest' read is no evidence."
            );
        } else {
            q.answerType = "bool";
            q.panel = true;
            string memory b = Strings.toString(s.toBlock);
            string memory nh = hexMin(s.threshold);
            string memory paren = catalogNonce
                ? string.concat(
                    "(hex ",
                    to,
                    ", block hash ",
                    Strings.toHexString(uint256(B_DEPLOY_HASH), 32),
                    "; the block in which the WhitelistCurator contract ",
                    Strings.toHexString(MAINNET_CURATOR),
                    " was deployed)"
                )
                : string.concat("(hex ", to, "; the last block of the spec's window)");
            q.question = string.concat(
                "At Ethereum mainnet block ",
                b,
                " ",
                paren,
                ", was the account nonce of address ",
                a,
                ", as returned by eth_getTransactionCount at that block, at least ",
                n,
                "? This asks about the account's nonce in the chain state at that block, not about its transaction history."
            );
            q.keys = new string[](4);
            q.values = new string[](4);
            q.keys[0] = "false";
            q.values[0] = string.concat(
                "false only if an endpoint with historical state returns a count at block ",
                to,
                " below ",
                n,
                " (",
                nh,
                "). If you could not read the historical count, write no answer; never answer false from a pruned, null or 'latest' read."
            );
            q.keys[1] = "method";
            q.values[1] = string.concat(
                "Call eth_getTransactionCount(",
                a,
                ", ",
                to,
                ") (hex block, not 'latest') on an endpoint with historical state, e.g. https://rpc.mevblocker.io or https://eth.drpc.org; cite endpoint and call. Pruned or unavailable state, errors or null (flashbots, 1rpc, cloudflare, publicnode) are no evidence: use another endpoint with historical state. Explorer transaction lists are not the nonce and are not evidence."
            );
            q.keys[2] = "true";
            q.values[2] = string.concat(
                "true only if an endpoint with historical state returns a transaction count at block ",
                to,
                " of at least ",
                n,
                " (",
                nh,
                ")."
            );
            q.keys[3] = "window";
            q.values[3] = string.concat(
                "The window is the single block ",
                b,
                "; it fixes which chain state to read. It is not a time range, and the current (latest) nonce is not the answer."
            );
        }
    }

    function opText(uint8 op) internal pure returns (string memory) {
        if (op == 1) return ">=";
        if (op == 2) return ">";
        if (op == 3) return "<=";
        if (op == 4) return "<";
        return "==";
    }

    // ------------------------------------------------------------------ serialisation

    /// @notice The request body: sorted keys, two-space indent, no trailing newline.
    function encodeBody(Question memory q, address consumer) internal view returns (bytes memory) {
        (uint16 panelSize, uint16 quorum) = q.panel ? (PANEL_PANEL, PANEL_QUORUM) : (CHAIN_PANEL, CHAIN_QUORUM);
        bytes memory defs;
        for (uint256 i; i < q.keys.length; ++i) {
            defs = bytes.concat(
                defs, i == 0 ? bytes("") : bytes(",\n"), '    "', bytes(q.keys[i]), '": "', bytes(q.values[i]), '"'
            );
        }
        bytes memory headPart =
            q.head == 0 ? bytes("") : bytes(string.concat('  "head": ', Strings.toString(q.head), ",\n"));
        return bytes.concat(
            bytes.concat(
                '{\n  "answerType": "',
                bytes(q.answerType),
                '",\n  "chainId": 1,\n  "consumer": {\n    "chainId": ',
                bytes(Strings.toString(block.chainid)),
                ',\n    "verifyingContract": "',
                bytes(Strings.toHexString(consumer)),
                '"\n  },\n  "definitions": {\n',
                defs,
                '\n  },\n  "evidence": "',
                q.panel ? bytes("panel") : bytes("chain"),
                '",\n',
                headPart
            ),
            bytes.concat(
                '  "panelSize": ',
                bytes(Strings.toString(panelSize)),
                ',\n  "question": "',
                bytes(q.question),
                '",\n  "quorum": ',
                bytes(Strings.toString(quorum)),
                ',\n  "v": 1,\n  "validForSeconds": ',
                bytes(Strings.toString(VALID_FOR_SECONDS)),
                ',\n  "window": {\n    "fromBlock": ',
                bytes(Strings.toString(q.fromBlock)),
                ',\n    "toBlock": ',
                bytes(Strings.toString(q.toBlock)),
                "\n  }\n}"
            )
        );
    }

    /// @notice The plane's canonical question document (RFC 8785): `answerType`, `chainId`,
    ///         `definitions`, `evidence` only when panel, `head` only when present, `question`, `v`,
    ///         `window` with `fromBlock` and `toBlock`.
    function canonical(Question memory q) internal pure returns (bytes memory) {
        bytes memory defs;
        for (uint256 i; i < q.keys.length; ++i) {
            defs = bytes.concat(
                defs, i == 0 ? bytes("") : bytes(","), '"', bytes(q.keys[i]), '":"', bytes(q.values[i]), '"'
            );
        }
        return bytes.concat(
            '{"answerType":"',
            bytes(q.answerType),
            '","chainId":1,"definitions":{',
            defs,
            "}",
            q.panel ? bytes(',"evidence":"panel"') : bytes(""),
            q.head == 0 ? bytes("") : bytes(string.concat(',"head":', Strings.toString(q.head))),
            ',"question":"',
            bytes(q.question),
            '","v":1,"window":{"fromBlock":',
            bytes(Strings.toString(q.fromBlock)),
            ',"toBlock":',
            bytes(Strings.toString(q.toBlock)),
            "}}"
        );
    }

    /// @notice Lowercase `0x` hex without leading zeros (`20` -> `0x14`, `0` -> `0x0`).
    function hexMin(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0x0";
        uint256 n;
        for (uint256 t = v; t != 0; t >>= 4) {
            n++;
        }
        bytes memory b = new bytes(n + 2);
        b[0] = "0";
        b[1] = "x";
        for (uint256 i = n + 1; i > 1; --i) {
            uint8 d = uint8(v & 0xf);
            b[i] = bytes1(d < 10 ? 48 + d : 87 + d);
            v >>= 4;
        }
        return string(b);
    }
}
