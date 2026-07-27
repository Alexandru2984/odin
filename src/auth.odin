package main

import "core:crypto"
import "core:crypto/argon2id"
import "core:slice"
import "core:strings"
import "core:sync"

// ---------------------------------------------------------------------------
// Accounts
//
// The old server had no notion of identity at all: `login <name>` set a
// display string, so impersonating any other user — including "System", whose
// name prefixed every broadcast — took one command.
//
// Passwords are hashed with Argon2id and a per-user random salt. Verification
// is constant-time. Nothing here ever logs or echoes a password.
// ---------------------------------------------------------------------------

User :: struct {
	name:        string, // owned; canonical (lower-case) form
	display:     string, // owned; as originally typed
	salt:        []byte, // owned
	hash:        []byte, // owned
	created:     i64,
	last_login:  i64,
	login_count: int,
}

User_DB :: struct {
	lock:  sync.Mutex,
	users: map[string]User, // keyed by canonical name; keys owned
	dirty: bool,

	// Argon2id costs 64 MiB per invocation. Without a bound, N concurrent
	// login attempts allocate N * 64 MiB and the service is OOM-killed inside
	// its 512 MiB cgroup — a trivial remote DoS. This admits only a few
	// hashes at a time; everyone else waits.
	hash_sema: sync.Sema,
}

Auth_Error :: enum {
	None,
	Exists,
	Not_Found,
	Bad_Credentials,
	Invalid_Name,
	Weak_Password,
	Too_Many_Users,
}

MAX_USERS :: 5000

auth_error_string :: proc(e: Auth_Error) -> string {
	switch e {
	case .None:
		return "success"
	case .Exists:
		return "that username is already registered"
	case .Not_Found:
		return "no such user"
	case .Bad_Credentials:
		return "incorrect username or password"
	case .Invalid_Name:
		return "invalid username"
	case .Weak_Password:
		return "password too weak"
	case .Too_Many_Users:
		return "user limit reached"
	}
	return "unknown error"
}

auth_init :: proc(db: ^User_DB) {
	db.users = make(map[string]User)
	sync.sema_post(&db.hash_sema, MAX_CONCURRENT_HASHES)
}

auth_destroy :: proc(db: ^User_DB) {
	for key, user in db.users {
		delete(key)
		delete(user.name)
		delete(user.display)
		delete(user.salt)
		delete(user.hash)
	}
	delete(db.users)
}

// Canonical form used for uniqueness and lookup, so `Alice` and `alice` are
// the same account and cannot be used to impersonate one another.
auth_canonical :: proc(name: string, allocator := context.allocator) -> string {
	return strings.to_lower(name, allocator)
}

// ---------------------------------------------------------------------------
// Hashing
// ---------------------------------------------------------------------------

@(private = "file")
hash_password :: proc(db: ^User_DB, password: string, salt: []byte) -> []byte {
	// Bound concurrent memory-hard hashing; see User_DB.hash_sema.
	sync.sema_wait(&db.hash_sema)
	defer sync.sema_post(&db.hash_sema)

	params := argon2id.Parameters {
		memory_size = ARGON2_MEMORY_KIB,
		passes      = ARGON2_PASSES,
		parallelism = ARGON2_PARALLELISM,
	}

	out := make([]byte, ARGON2_TAG_BYTES)
	_ = argon2id.derive(&params, transmute([]byte)password, salt, out)
	return out
}

validate_password :: proc(password: string) -> (ok: bool, reason: string) {
	if len(password) < MIN_PASSWORD_LEN {
		return false, "password must be at least 8 characters"
	}
	if len(password) > MAX_PASSWORD_LEN {
		return false, "password must be at most 128 characters"
	}
	// Control characters cannot be typed back reliably and would break the
	// line editor's assumptions.
	if !is_clean_text(password) {
		return false, "password contains unsupported characters"
	}
	return true, ""
}

// ---------------------------------------------------------------------------
// Operations
// ---------------------------------------------------------------------------

auth_register :: proc(db: ^User_DB, name: string, password: string) -> Auth_Error {
	if ok, _ := validate_username(name); !ok {
		return .Invalid_Name
	}
	if ok, _ := validate_password(password); !ok {
		return .Weak_Password
	}

	canon := auth_canonical(name, context.temp_allocator)

	// Check for an existing account before doing the expensive hash.
	sync.mutex_lock(&db.lock)
	if canon in db.users {
		sync.mutex_unlock(&db.lock)
		return .Exists
	}
	if len(db.users) >= MAX_USERS {
		sync.mutex_unlock(&db.lock)
		return .Too_Many_Users
	}
	sync.mutex_unlock(&db.lock)

	salt := make([]byte, ARGON2_SALT_BYTES)
	crypto.rand_bytes(salt)
	hash := hash_password(db, password, salt)

	sync.mutex_lock(&db.lock)
	defer sync.mutex_unlock(&db.lock)

	// Re-check: another connection may have registered the same name while we
	// were hashing.
	if canon in db.users {
		delete(salt)
		delete(hash)
		return .Exists
	}

	now := unix_now()
	db.users[strings.clone(canon)] = User {
		name        = strings.clone(canon),
		display     = strings.clone(name),
		salt        = salt,
		hash        = hash,
		created     = now,
		last_login  = now,
		login_count = 1,
	}
	db.dirty = true

	return .None
}

// Verifies credentials. Returns the account's display name on success.
//
// Always performs a full hash, even for a username that does not exist, so
// response timing does not reveal which accounts are registered.
auth_verify :: proc(
	db: ^User_DB,
	name: string,
	password: string,
	allocator := context.allocator,
) -> (display: string, err: Auth_Error) {
	canon := auth_canonical(name, context.temp_allocator)

	sync.mutex_lock(&db.lock)
	user, found := db.users[canon]
	// Copy what we need so the hash happens outside the lock.
	salt: []byte
	expected: []byte
	if found {
		salt = slice.clone(user.salt, context.temp_allocator)
		expected = slice.clone(user.hash, context.temp_allocator)
	}
	sync.mutex_unlock(&db.lock)

	if !found {
		// Hash against a dummy salt to keep the timing profile identical to a
		// real attempt, then fail.
		dummy := make([]byte, ARGON2_SALT_BYTES, context.temp_allocator)
		throwaway := hash_password(db, password, dummy)
		delete(throwaway)
		return "", .Bad_Credentials
	}

	computed := hash_password(db, password, salt)
	defer delete(computed)

	if crypto.compare_constant_time(computed, expected) != 1 {
		return "", .Bad_Credentials
	}

	sync.mutex_lock(&db.lock)
	defer sync.mutex_unlock(&db.lock)

	if stored, ok := db.users[canon]; ok {
		updated := stored
		updated.last_login = unix_now()
		updated.login_count += 1
		db.users[canon] = updated
		db.dirty = true
		return strings.clone(updated.display, allocator), .None
	}

	return strings.clone(name, allocator), .None
}

auth_change_password :: proc(
	db: ^User_DB,
	name: string,
	old_password: string,
	new_password: string,
) -> Auth_Error {
	if ok, _ := validate_password(new_password); !ok {
		return .Weak_Password
	}

	display, err := auth_verify(db, name, old_password, context.temp_allocator)
	if err != .None {
		return err
	}
	_ = display

	canon := auth_canonical(name, context.temp_allocator)

	salt := make([]byte, ARGON2_SALT_BYTES)
	crypto.rand_bytes(salt)
	hash := hash_password(db, new_password, salt)

	sync.mutex_lock(&db.lock)
	defer sync.mutex_unlock(&db.lock)

	stored, ok := db.users[canon]
	if !ok {
		delete(salt)
		delete(hash)
		return .Not_Found
	}

	updated := stored
	delete(updated.salt)
	delete(updated.hash)
	updated.salt = salt
	updated.hash = hash
	db.users[canon] = updated
	db.dirty = true

	return .None
}

auth_exists :: proc(db: ^User_DB, name: string) -> bool {
	canon := auth_canonical(name, context.temp_allocator)
	sync.mutex_lock(&db.lock)
	defer sync.mutex_unlock(&db.lock)
	return canon in db.users
}

auth_count :: proc(db: ^User_DB) -> int {
	sync.mutex_lock(&db.lock)
	defer sync.mutex_unlock(&db.lock)
	return len(db.users)
}

// Public profile information, for `finger`-style lookups. Never exposes salt
// or hash.
User_Info :: struct {
	display:     string, // owned
	created:     i64,
	last_login:  i64,
	login_count: int,
}

auth_info :: proc(
	db: ^User_DB,
	name: string,
	allocator := context.allocator,
) -> (info: User_Info, ok: bool) {
	canon := auth_canonical(name, context.temp_allocator)
	sync.mutex_lock(&db.lock)
	defer sync.mutex_unlock(&db.lock)

	user, found := db.users[canon]
	if !found {
		return {}, false
	}
	return User_Info {
			display = strings.clone(user.display, allocator),
			created = user.created,
			last_login = user.last_login,
			login_count = user.login_count,
		},
		true
}

// All registered display names, sorted by creation time. Caller owns them.
auth_list :: proc(db: ^User_DB, allocator := context.allocator) -> []string {
	sync.mutex_lock(&db.lock)
	defer sync.mutex_unlock(&db.lock)

	names := make([dynamic]string, allocator)
	for _, user in db.users {
		append(&names, strings.clone(user.display, allocator))
	}
	return names[:]
}
