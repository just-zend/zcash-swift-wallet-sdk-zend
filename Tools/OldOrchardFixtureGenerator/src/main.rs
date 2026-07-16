use std::{
    collections::BTreeMap,
    convert::Infallible,
    env,
    fmt::Write as _,
    fs,
    path::{Path, PathBuf},
};

use prost::Message;
use rand::SeedableRng;
use rand_chacha::ChaCha20Rng;
use rusqlite::{Connection, params};
use zcash_client_backend::{
    data_api::{
        chain::{BlockSource, ChainState, error::Error as ChainError},
        testing::{
            CacheInsertionResult, DataStoreFactory, InitialChainState, TestBuilder, TestCache,
            orchard::OrchardPoolTester,
            pool::dsl::{TestDsl, TestScenario},
        },
    },
    proto::compact_formats::CompactBlock,
};
use zcash_client_sqlite::{
    AccountUuid, WalletDb,
    error::SqliteClientError,
    util::SystemClock,
    wallet::{Account, init::WalletMigrator},
};
use zcash_keys::{address::Address, keys::transparent::gap_limits::GapLimits};
use zcash_protocol::{
    TxId,
    consensus::{BlockHeight, Network},
    local_consensus::LocalNetwork,
    value::Zatoshis,
};

const IRONWOOD_TESTNET_ACTIVATION: u32 = 4_134_000;
const IRONWOOD_MAINNET_ACTIVATION: u32 = 3_428_143;
const ORCHARD_VALUE: u64 = 123_456_789;
const ACCOUNT_UUID: [u8; 16] = [
    0x67, 0x3a, 0x4e, 0x0e, 0xc2, 0x27, 0x46, 0x42, 0x98, 0x64, 0x5e, 0xaf, 0x42, 0x5b, 0xe4, 0x2e,
];
const ACCOUNT_UUID_TEXT: &str = "673a4e0e-c227-4642-9864-5eaf425be42e";

#[derive(Clone, Copy)]
enum FixtureNetwork {
    Testnet,
    Mainnet,
}

impl FixtureNetwork {
    fn activation_height(self) -> u32 {
        match self {
            Self::Testnet => IRONWOOD_TESTNET_ACTIVATION,
            Self::Mainnet => IRONWOOD_MAINNET_ACTIVATION,
        }
    }

    fn consensus_network(self) -> Network {
        match self {
            Self::Testnet => Network::TestNetwork,
            Self::Mainnet => Network::MainNetwork,
        }
    }

    fn label(self) -> &'static str {
        match self {
            Self::Testnet => "testnet",
            Self::Mainnet => "mainnet",
        }
    }
}

#[derive(Default)]
struct MemoryBlockSource {
    blocks: BTreeMap<u32, CompactBlock>,
}

impl BlockSource for MemoryBlockSource {
    type Error = Infallible;

    fn with_blocks<F, WalletError>(
        &self,
        from_height: Option<BlockHeight>,
        limit: Option<usize>,
        mut with_block: F,
    ) -> Result<(), ChainError<WalletError, Self::Error>>
    where
        F: FnMut(CompactBlock) -> Result<(), ChainError<WalletError, Self::Error>>,
    {
        let start = from_height.map_or(0, u32::from);
        for block in self.blocks.range(start..).take(limit.unwrap_or(usize::MAX)) {
            with_block(block.1.clone())?;
        }
        Ok(())
    }
}

struct MemoryInsertion {
    txids: Vec<TxId>,
}

impl CacheInsertionResult for MemoryInsertion {
    fn txids(&self) -> &[TxId] {
        &self.txids
    }
}

struct MemoryCache {
    source: MemoryBlockSource,
}

impl MemoryCache {
    fn new() -> Self {
        Self {
            source: MemoryBlockSource::default(),
        }
    }
}

impl TestCache for MemoryCache {
    type BsError = Infallible;
    type BlockSource = MemoryBlockSource;
    type InsertResult = MemoryInsertion;

    fn block_source(&self) -> &Self::BlockSource {
        &self.source
    }

    fn insert(&mut self, block: &CompactBlock) -> Self::InsertResult {
        let txids = block.vtx.iter().map(|tx| tx.txid()).collect();
        self.source
            .blocks
            .insert(u32::from(block.height()), block.clone());
        MemoryInsertion { txids }
    }

    fn truncate_to_height(&mut self, height: BlockHeight) {
        let height = u32::from(height);
        self.source.blocks.retain(|block, _| *block <= height);
    }
}

type FileWalletDb = WalletDb<Connection, Network, SystemClock, ChaCha20Rng>;

struct FileDbFactory {
    path: PathBuf,
    network: Network,
}

impl DataStoreFactory for FileDbFactory {
    type Error = String;
    type AccountId = AccountUuid;
    type Account = Account;
    type DsError = SqliteClientError;
    type DataStore = FileWalletDb;

    fn new_data_store(
        &self,
        _network: LocalNetwork,
        gap_limits: Option<GapLimits>,
    ) -> Result<Self::DataStore, Self::Error> {
        let mut db = WalletDb::for_path(
            &self.path,
            self.network,
            SystemClock,
            ChaCha20Rng::seed_from_u64(0x5a45_4e44_4f4c_4436),
        )
        .map_err(|error| error.to_string())?;
        if let Some(gap_limits) = gap_limits {
            db = db.with_gap_limits(gap_limits);
        }
        WalletMigrator::new()
            .init_or_migrate(&mut db)
            .map_err(|error| error.to_string())?;
        Ok(db)
    }
}

type Scenario = TestDsl<TestScenario<OrchardPoolTester, MemoryCache, FileDbFactory>>;

fn canonicalize_cached_addresses(connection: &Connection, network: &Network) -> Result<(), String> {
    let rows = {
        let mut statement = connection
            .prepare(
                "SELECT id, address, cached_transparent_receiver_address
                 FROM addresses ORDER BY id",
            )
            .map_err(|error| error.to_string())?;
        statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Option<String>>(2)?,
                ))
            })
            .map_err(|error| error.to_string())?
            .collect::<Result<Vec<_>, _>>()
            .map_err(|error| error.to_string())?
    };

    for (id, encoded, cached_transparent) in rows {
        let canonical = Address::decode(network, &encoded)
            .ok_or_else(|| format!("address row {id} is not valid for the selected network"))?
            .encode(network);
        let canonical_cached = cached_transparent
            .map(|encoded| {
                Address::decode(network, &encoded)
                    .ok_or_else(|| {
                        format!(
                            "cached transparent receiver in address row {id} is not valid for the selected network"
                        )
                    })
                    .map(|address| address.encode(network))
            })
            .transpose()?;
        connection
            .execute(
                "UPDATE addresses
                 SET address = ?1, cached_transparent_receiver_address = ?2
                 WHERE id = ?3",
                params![canonical, canonical_cached, id],
            )
            .map_err(|error| error.to_string())?;
    }
    Ok(())
}

fn compact_blocks_path(wallet_path: &Path) -> PathBuf {
    wallet_path.with_extension("compactblocks")
}

fn write_compact_blocks(path: &Path, blocks: &BTreeMap<u32, CompactBlock>) -> Result<(), String> {
    let mut encoded = String::new();
    for (height, block) in blocks {
        write!(&mut encoded, "{height}:").map_err(|error| error.to_string())?;
        for byte in block.encode_to_vec() {
            write!(&mut encoded, "{byte:02x}").map_err(|error| error.to_string())?;
        }
        encoded.push('\n');
    }
    fs::write(path, encoded).map_err(|error| error.to_string())
}

fn generate(path: &Path, fixture_network: FixtureNetwork) -> Result<(), String> {
    if path.exists() {
        fs::remove_file(path).map_err(|error| error.to_string())?;
    }
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }

    let activation_height = fixture_network.activation_height();
    let fixture_start_height = activation_height - 10;
    let fixture_end_height = activation_height + 10;
    let initial_height = BlockHeight::from_u32(fixture_start_height - 1);
    let mut scenario: Scenario = TestDsl::from(
        TestBuilder::new()
            .with_initial_chain_state(|_, _| InitialChainState {
                chain_state: ChainState::empty(
                    initial_height,
                    zcash_primitives::block::BlockHash([0; 32]),
                ),
                prior_sapling_roots: vec![],
                prior_orchard_roots: vec![],
            })
            .with_data_store_factory(FileDbFactory {
                path: path.to_path_buf(),
                network: fixture_network.consensus_network(),
            })
            .with_block_cache(MemoryCache::new())
            .with_account_having_current_birthday(),
    )
    .build::<OrchardPoolTester>();

    let (note_height, _, _) =
        scenario.add_a_single_note_checking_balance(Zatoshis::const_from_u64(ORCHARD_VALUE));
    assert_eq!(u32::from(note_height), fixture_start_height);
    let final_height = scenario.add_empty_blocks(
        usize::try_from(fixture_end_height - fixture_start_height).expect("height delta fits"),
    );
    assert_eq!(u32::from(final_height), fixture_end_height);

    let compact_blocks_path = compact_blocks_path(path);
    write_compact_blocks(&compact_blocks_path, &scenario.cache().blocks)?;

    drop(scenario);

    let connection = Connection::open(path).map_err(|error| error.to_string())?;
    // The test harness drives deterministic compact blocks with LocalNetwork, while the wallet DB
    // itself is created with the selected production consensus network. This derives the exact
    // coin-type-specific account and cached addresses that the released iOS FFI created. Decode and
    // re-encode every cached address as a final fail-closed canonical-network check.
    canonicalize_cached_addresses(&connection, &fixture_network.consensus_network())?;
    connection
        .execute(
            "UPDATE accounts SET uuid = ?1",
            params![ACCOUNT_UUID.as_slice()],
        )
        .map_err(|error| error.to_string())?;
    connection
        .execute_batch(
            "CREATE TEMP TABLE sorted_migrations AS
                 SELECT id FROM schemer_migrations ORDER BY hex(id);
             DELETE FROM schemer_migrations;
             INSERT INTO schemer_migrations (id)
                 SELECT id FROM sorted_migrations ORDER BY hex(id);
             DROP TABLE sorted_migrations;
             PRAGMA wal_checkpoint(TRUNCATE);
             VACUUM;",
        )
        .map_err(|error| error.to_string())?;

    println!("fixture={}", path.display());
    println!("compact_blocks={}", compact_blocks_path.display());
    println!("network={}", fixture_network.label());
    println!("account_uuid={ACCOUNT_UUID_TEXT}");
    println!("seed_hex={}", "00".repeat(32));
    println!("orchard_value={ORCHARD_VALUE}");
    println!(
        "scanned_range={fixture_start_height}..{}",
        fixture_end_height + 1
    );
    Ok(())
}

fn main() {
    let mut args = env::args_os().skip(1);
    let output = args.next().map(PathBuf::from).unwrap_or_else(|| {
        PathBuf::from("Tests/TestUtils/Resources/zend_2_6_0_alpha_6_orchard.sqlite")
    });
    let fixture_network = match args
        .next()
        .and_then(|value| value.into_string().ok())
        .as_deref()
    {
        None | Some("testnet") => FixtureNetwork::Testnet,
        Some("mainnet") => FixtureNetwork::Mainnet,
        Some(other) => {
            eprintln!("unsupported fixture network: {other}; expected testnet or mainnet");
            std::process::exit(2);
        }
    };
    if args.next().is_some() {
        eprintln!("usage: old-orchard-fixture-generator [output.sqlite] [testnet|mainnet]");
        std::process::exit(2);
    }
    if let Err(error) = generate(&output, fixture_network) {
        eprintln!("failed to generate old Orchard fixture: {error}");
        std::process::exit(1);
    }
}
