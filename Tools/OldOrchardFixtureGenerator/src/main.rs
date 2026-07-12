use std::{
    collections::BTreeMap,
    convert::Infallible,
    env, fs,
    path::{Path, PathBuf},
};

use rand::SeedableRng;
use rand_chacha::ChaCha20Rng;
use rusqlite::{Connection, params};
use zcash_client_backend::{
    data_api::{
        Account as _,
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
use zcash_keys::keys::transparent::gap_limits::GapLimits;
use zcash_protocol::{
    TxId,
    consensus::{BlockHeight, Network},
    local_consensus::LocalNetwork,
    value::Zatoshis,
};

const IRONWOOD_TESTNET_ACTIVATION: u32 = 4_134_000;
const FIXTURE_START_HEIGHT: u32 = IRONWOOD_TESTNET_ACTIVATION - 10;
const FIXTURE_END_HEIGHT: u32 = IRONWOOD_TESTNET_ACTIVATION + 10;
const ORCHARD_VALUE: u64 = 123_456_789;
const ACCOUNT_UUID: [u8; 16] = [
    0x67, 0x3a, 0x4e, 0x0e, 0xc2, 0x27, 0x46, 0x42, 0x98, 0x64, 0x5e, 0xaf, 0x42, 0x5b, 0xe4, 0x2e,
];
const ACCOUNT_UUID_TEXT: &str = "673a4e0e-c227-4642-9864-5eaf425be42e";

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

type FileWalletDb = WalletDb<Connection, LocalNetwork, SystemClock, ChaCha20Rng>;

struct FileDbFactory {
    path: PathBuf,
}

impl DataStoreFactory for FileDbFactory {
    type Error = String;
    type AccountId = AccountUuid;
    type Account = Account;
    type DsError = SqliteClientError;
    type DataStore = FileWalletDb;

    fn new_data_store(
        &self,
        network: LocalNetwork,
        gap_limits: Option<GapLimits>,
    ) -> Result<Self::DataStore, Self::Error> {
        let mut db = WalletDb::for_path(
            &self.path,
            network,
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

fn generate(path: &Path) -> Result<(), String> {
    if path.exists() {
        fs::remove_file(path).map_err(|error| error.to_string())?;
    }
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }

    let initial_height = BlockHeight::from_u32(FIXTURE_START_HEIGHT - 1);
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
            })
            .with_block_cache(MemoryCache::new())
            .with_account_having_current_birthday(),
    )
    .build::<OrchardPoolTester>();

    let (note_height, _, _) =
        scenario.add_a_single_note_checking_balance(Zatoshis::const_from_u64(ORCHARD_VALUE));
    assert_eq!(u32::from(note_height), FIXTURE_START_HEIGHT);
    let final_height = scenario.add_empty_blocks(
        usize::try_from(FIXTURE_END_HEIGHT - FIXTURE_START_HEIGHT).expect("height delta fits"),
    );
    assert_eq!(u32::from(final_height), FIXTURE_END_HEIGHT);

    let account = scenario.get_account();
    let ufvk = account.ufvk().expect("the generated account has a UFVK");
    let testnet_ufvk = ufvk.encode(&Network::TestNetwork);
    let testnet_uivk = ufvk
        .to_unified_incoming_viewing_key()
        .encode(&Network::TestNetwork);
    drop(scenario);

    let connection = Connection::open(path).map_err(|error| error.to_string())?;
    // The upstream deterministic harness uses LocalNetwork, whose key material has the test coin
    // type but whose human-readable key prefix is `regtest`. The released iOS FFI invoked the same
    // backend with TestNetwork. Re-encode the exact generated UFVK/UIVK for TestNetwork so the
    // fixture matches that released entry point; no schema or key material is changed.
    connection
        .execute(
            "UPDATE accounts SET uuid = ?1, ufvk = ?2, uivk = ?3",
            params![ACCOUNT_UUID.as_slice(), testnet_ufvk, testnet_uivk],
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
    println!("account_uuid={ACCOUNT_UUID_TEXT}");
    println!("seed_hex={}", "00".repeat(32));
    println!("orchard_value={ORCHARD_VALUE}");
    println!(
        "scanned_range={FIXTURE_START_HEIGHT}..{}",
        FIXTURE_END_HEIGHT + 1
    );
    Ok(())
}

fn main() {
    let output = env::args_os().nth(1).map(PathBuf::from).unwrap_or_else(|| {
        PathBuf::from("Tests/TestUtils/Resources/zend_2_6_0_alpha_6_orchard.sqlite")
    });
    if let Err(error) = generate(&output) {
        eprintln!("failed to generate old Orchard fixture: {error}");
        std::process::exit(1);
    }
}
