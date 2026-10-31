package app.amber.ai.core

import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

fun createSSHKeyListToolDeclaration(): Tool = Tool(
    name = "ssh_key_list",
    description = """
        List SSH keys stored on this device: id, name, algorithm, OpenSSH public key,
        SHA256 fingerprint, protection and which profiles use each key. Private keys
        and passphrases are never returned. Read-only: no approval.
    """.trimIndent().replace("\n", " "),
    parameters = {
        InputSchema.Obj(
            properties = buildJsonObject {},
            required = emptyList()
        )
    },
    needsApproval = false,
    execute = { emptyList() }
)

fun createSSHKeyGenerateToolDeclaration(): Tool = Tool(
    name = "ssh_key_generate",
    description = """
        Generate a new SSH key pair inside the device's secure storage. Returns only
        the OpenSSH public key and SHA256 fingerprint; the private key never leaves
        secure storage. Workflow when no key exists yet: call ssh_key_generate first,
        give the returned public key to the user to add to the server's authorized_keys,
        and then create or update the SSH profile referencing key_id. Requires foreground approval.
    """.trimIndent().replace("\n", " "),
    parameters = {
        InputSchema.Obj(
            properties = buildJsonObject {
                put("name", buildJsonObject {
                    put("type", "string")
                    put("description", "Unique display name, 1-64 chars.")
                })
                put("type", buildJsonObject {
                    put("type", "string")
                    put("enum", buildJsonArray { add("ed25519"); add("ecdsa-p256-se") })
                    put("default", "ed25519")
                    put("description", "ed25519 (default, Keychain). ecdsa-p256-se: hardware Secure Enclave key, non-exportable (iOS/macOS only).")
                })
                put("require_user_presence", buildJsonObject {
                    put("type", "boolean")
                    put("default", false)
                    put("description", "Require Face ID/passcode for every use. Background jobs will fail while this is on.")
                })
            },
            required = listOf("name")
        )
    },
    needsApproval = true,
    allowsAutoApproval = false,
    execute = { emptyList() }
)

fun createSSHKeyImportToolDeclaration(): Tool = Tool(
    name = "ssh_key_import",
    description = """
        Import an existing OpenSSH or ECDSA PEM private key (optionally passphrase-protected)
        into secure storage. Returns only the OpenSSH public key and fingerprint. The private
        key and passphrase are never returned, logged or re-uploaded. Requires foreground approval.
    """.trimIndent().replace("\n", " "),
    parameters = {
        InputSchema.Obj(
            properties = buildJsonObject {
                put("name", buildJsonObject {
                    put("type", "string")
                    put("description", "Unique display name, 1-64 chars.")
                })
                put("private_key", buildJsonObject {
                    put("type", "string")
                    put("description", "OpenSSH (Ed25519/ECDSA) or ECDSA PEM private key text, max 64 KB.")
                })
                put("passphrase", buildJsonObject {
                    put("type", "string")
                    put("description", "Optional passphrase if the OpenSSH private key is encrypted. Used to decrypt at import and never returned.")
                })
            },
            required = listOf("name", "private_key")
        )
    },
    needsApproval = true,
    allowsAutoApproval = false,
    execute = { emptyList() }
)

fun createSSHKeyDeleteToolDeclaration(): Tool = Tool(
    name = "ssh_key_delete",
    description = """
        Delete one stored SSH key and its secure-storage item. Fails with key_in_use
        while any profile references it. The host shows a destructive foreground approval card.
    """.trimIndent().replace("\n", " "),
    parameters = {
        InputSchema.Obj(
            properties = buildJsonObject {
                put("key_id", buildJsonObject {
                    put("type", "string")
                    put("description", "Required. Id from ssh_key_list.")
                })
            },
            required = listOf("key_id")
        )
    },
    needsApproval = true,
    allowsAutoApproval = false,
    execute = { emptyList() }
)

/**
 * SSH profile management tools (iOS host executes; they edit the same store the
 * settings page edits, so changes are visible immediately).
 *
 * Credentials are write-only: `password` / `private_key` are accepted as input
 * and stored in the existing Keychain item, but no tool result, log or approval
 * preview ever returns them, and the host redacts those fields before the tool
 * call is persisted back into the conversation. The three writers are declared
 * non-auto-approvable so an ordinary "auto approve" policy cannot run them; the
 * host gates them on the high-risk approval path that a lock-screen or phone
 * push cannot answer.
 */
fun createSSHProfileListToolDeclaration(): Tool = Tool(
    name = "ssh_profile_list",
    description = """
        List the saved Remote SSH profiles with id, name, host, port, username,
        auth_method, key_id, key_fingerprint, jump_profile_id, resolved route and
        route_ready, plus whether a credential is stored (booleans only - the
        password or private key itself is never returned). Read-only: no approval.
    """.trimIndent().replace("\n", " "),
    parameters = {
        InputSchema.Obj(
            properties = buildJsonObject {},
            required = emptyList()
        )
    },
    needsApproval = false,
    execute = { emptyList() }
)

fun createSSHProfileCreateToolDeclaration(): Tool = Tool(
    name = "ssh_profile_create",
    description = """
        Create one saved Remote SSH profile. Requires host and username; port defaults to
        22 and auth_method defaults to password (or key when key_id or private_key is
        supplied). When no SSH key exists yet, call ssh_key_generate first, give the
        public key to the user to add to authorized_keys, then create the profile with
        key_id. Optional jump_profile_id chains up to 3 jump hosts (ProxyJump). The
        credential is written to the local Keychain and is never echoed back. The host
        shows a foreground approval card before writing.
    """.trimIndent().replace("\n", " "),
    parameters = {
        InputSchema.Obj(
            properties = buildJsonObject {
                put("name", buildJsonObject {
                    put("type", "string")
                    put("description", "Optional display name; must be unique among profiles. Defaults to user@host.")
                })
                put("host", buildJsonObject { put("type", "string") })
                put("port", buildJsonObject {
                    put("type", "integer")
                    put("description", "Optional. 1-65535. Defaults to 22.")
                })
                put("username", buildJsonObject { put("type", "string") })
                put("auth_method", buildJsonObject {
                    put("type", "string")
                    put("enum", buildJsonArray { add("password"); add("key"); add("private_key") })
                    put("description", "Optional. \"password\" or \"key\" (legacy value \"private_key\" is accepted and treated as \"key\").")
                })
                put("key_id", buildJsonObject {
                    put("type", "string")
                    put("description", "Optional id from ssh_key_list. Required when auth_method=key unless private_key is supplied (legacy import).")
                })
                put("jump_profile_id", buildJsonObject {
                    put("type", "string")
                    put("description", "Optional jump host profile id (OpenSSH -J). Chains up to 3 jump hosts; cycles are rejected. Pass empty string to connect directly.")
                })
                put("password", buildJsonObject {
                    put("type", "string")
                    put("description", "Optional SSH password when auth_method=password. Stored in the Keychain; never returned or re-uploaded.")
                })
                put("private_key", buildJsonObject {
                    put("type", "string")
                    put("description", "Legacy: OpenSSH Ed25519/ECDSA or ECDSA PEM private key text (max 64 KB), imported as a stored key and referenced via key_id. Never returned or re-uploaded.")
                })
                put("passphrase", buildJsonObject {
                    put("type", "string")
                    put("description", "Optional passphrase for an encrypted legacy private_key. Never returned or re-uploaded.")
                })
            },
            required = listOf("host", "username")
        )
    },
    needsApproval = true,
    allowsAutoApproval = false,
    execute = { emptyList() }
)

fun createSSHProfileUpdateToolDeclaration(): Tool = Tool(
    name = "ssh_profile_update",
    description = """
        Update one existing Remote SSH profile by profile_id. Only provided fields change;
        omit password/private_key/key_id to keep the stored credential. Changing host, port,
        username or auth_method without a new credential clears the stored credential;
        changing jump_profile_id invalidates this profile's trusted host key.
        The host shows a foreground approval card before writing.
    """.trimIndent().replace("\n", " "),
    parameters = {
        InputSchema.Obj(
            properties = buildJsonObject {
                put("profile_id", buildJsonObject {
                    put("type", "string")
                    put("description", "Required. Id from ssh_profile_list.")
                })
                put("name", buildJsonObject {
                    put("type", "string")
                    put("description", "Optional new display name; must stay unique.")
                })
                put("host", buildJsonObject {
                    put("type", "string")
                    put("description", "Optional new host.")
                })
                put("port", buildJsonObject {
                    put("type", "integer")
                    put("description", "Optional new port, 1-65535.")
                })
                put("username", buildJsonObject {
                    put("type", "string")
                    put("description", "Optional new username.")
                })
                put("auth_method", buildJsonObject {
                    put("type", "string")
                    put("enum", buildJsonArray { add("password"); add("key"); add("private_key") })
                    put("description", "Optional. \"password\" or \"key\" (legacy \"private_key\" is accepted and treated as \"key\").")
                })
                put("key_id", buildJsonObject {
                    put("type", "string")
                    put("description", "Optional stored key id from ssh_key_list when auth_method=key.")
                })
                put("jump_profile_id", buildJsonObject {
                    put("type", "string")
                    put("description", "Optional jump host profile id (OpenSSH -J). Pass empty string to clear jump host and connect directly.")
                })
                put("password", buildJsonObject {
                    put("type", "string")
                    put("description", "Optional replacement password. Never returned or re-uploaded.")
                })
                put("private_key", buildJsonObject {
                    put("type", "string")
                    put("description", "Optional legacy replacement private key (imported into key store). Never returned or re-uploaded.")
                })
                put("passphrase", buildJsonObject {
                    put("type", "string")
                    put("description", "Optional passphrase for an encrypted legacy private_key. Never returned or re-uploaded.")
                })
            },
            required = listOf("profile_id")
        )
    },
    needsApproval = true,
    allowsAutoApproval = false,
    execute = { emptyList() }
)

fun createSSHProfileDeleteToolDeclaration(): Tool = Tool(
    name = "ssh_profile_delete",
    description = """
        Delete one saved Remote SSH profile by profile_id and remove its inline Keychain
        credential. Referenced stored keys are retained. Fails with in_use_as_jump if another profile references it as
        jump_profile_id. Terminal jobs that still reference the profile fail with
        profile_not_found instead of being stopped. The host shows a destructive
        foreground approval card before deleting.
    """.trimIndent().replace("\n", " "),
    parameters = {
        InputSchema.Obj(
            properties = buildJsonObject {
                put("profile_id", buildJsonObject {
                    put("type", "string")
                    put("description", "Required. Id from ssh_profile_list.")
                })
            },
            required = listOf("profile_id")
        )
    },
    needsApproval = true,
    allowsAutoApproval = false,
    execute = { emptyList() }
)

/**
 * Theme pack tools (iOS host executes). Status is a pure catalog; import
 * try-on + persist requires a foreground approval card. Packs may define a
 * complete visual treatment (including per-mode surfaces, gradients, patterns,
 * and chrome geometry) — never list layout, appearance mode, or chat fonts.
 */
