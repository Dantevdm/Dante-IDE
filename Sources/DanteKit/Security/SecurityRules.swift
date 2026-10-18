import Foundation

/// A pattern that marks a problem on one line of the files it applies to.
struct LineRule: Sendable {
    enum Files: Sendable {
        /// By extension, lowercased, without the dot.
        case extensions(Set<String>)
        /// Dockerfiles, compose files, workflows and other files known by name or place.
        case kind(FileKind)
        case any
    }

    enum FileKind: Sendable { case dockerfile, compose, workflow, terraform, kubernetes, plist }

    let id: String
    let category: SecurityFinding.Category
    let severity: SecurityFinding.Severity
    let title: String
    let why: String
    let fix: String
    let reference: String?
    let files: Files
    let pattern: NSRegularExpression
    /// The line is fine after all when this matches it.
    let unless: NSRegularExpression?
    /// Lines that are comments aren't checked (secret rules check them).
    let skipsComments: Bool
    /// Mask what the pattern matched in the evidence.
    let masks: Bool

    init(_ id: String, _ category: SecurityFinding.Category, _ severity: SecurityFinding.Severity, _ title: String,
         why: String, fix: String, ref: String? = nil, files: Files, _ pattern: String, unless: String? = nil,
         skipsComments: Bool = true, masks: Bool = false) {
        self.id = id
        self.category = category
        self.severity = severity
        self.title = title
        self.why = why
        self.fix = fix
        self.reference = ref
        self.files = files
        self.pattern = try! NSRegularExpression(pattern: pattern)
        self.unless = unless.map { try! NSRegularExpression(pattern: $0) }
        self.skipsComments = skipsComments
        self.masks = masks
    }
}

enum SecurityRules {
    static let js: Set<String> = ["js", "jsx", "ts", "tsx", "mjs", "cjs", "vue", "svelte"]
    static let python: Set<String> = ["py"]
    static let go: Set<String> = ["go"]
    static let shell: Set<String> = ["sh", "bash", "zsh"]

    // MARK: Secrets

    static let secrets: [LineRule] = [
        LineRule("secret.aws", .secrets, .critical, "AWS access key",
                 why: "Anyone with the repository can use this key against your AWS account until it's revoked.",
                 fix: "Revoke the key in IAM, then load credentials from the environment or an AWS profile.", ref: "CWE-798",
                 files: .any, #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#, skipsComments: false, masks: true),
        LineRule("secret.private-key", .secrets, .critical, "Private key in the code",
                 why: "A private key in the repository lets anyone who can read it impersonate you or decrypt your traffic.",
                 fix: "Remove the key, rotate it, and keep keys in the Keychain, a secret manager or an ignored file.", ref: "CWE-321",
                 files: .any, #"-----BEGIN (?:RSA |EC |OPENSSH |DSA |PGP |ENCRYPTED )?PRIVATE KEY"#, skipsComments: false),
        LineRule("secret.anthropic", .secrets, .critical, "Anthropic API key",
                 why: "The key bills your account and reads your organisation's data.",
                 fix: "Revoke it in the Console and read it from the environment.", ref: "CWE-798",
                 files: .any, #"\bsk-(?:ant)-[A-Za-z0-9_\-]{20,}"#, skipsComments: false, masks: true),
        LineRule("secret.openai", .secrets, .critical, "OpenAI API key",
                 why: "The key bills your account.", fix: "Revoke it and read it from the environment.", ref: "CWE-798",
                 files: .any, #"\bsk-(?:proj-)?[A-Za-z0-9_\-]{32,}"#, unless: #"sk-(?:ant)-"#, skipsComments: false, masks: true),
        LineRule("secret.github", .secrets, .critical, "GitHub token",
                 why: "The token acts as you on GitHub: code, packages and workflows.",
                 fix: "Revoke it under Settings › Developer settings and use the environment or `gh auth`.", ref: "CWE-798",
                 files: .any, #"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}|\bgithub_pat_[A-Za-z0-9_]{40,}"#, skipsComments: false, masks: true),
        LineRule("secret.slack", .secrets, .high, "Slack token",
                 why: "The token can read and post in your workspace.", fix: "Revoke it and load it from the environment.", ref: "CWE-798",
                 files: .any, #"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#, skipsComments: false, masks: true),
        LineRule("secret.stripe", .secrets, .critical, "Stripe live key",
                 why: "A live key can move money.", fix: "Roll the key in the Stripe dashboard and keep it in a secret manager.", ref: "CWE-798",
                 files: .any, #"\b[rs]k_live_[A-Za-z0-9]{20,}"#, skipsComments: false, masks: true),
        LineRule("secret.google", .secrets, .high, "Google API key",
                 why: "Unrestricted Google keys run up bills and reach your APIs.",
                 fix: "Restrict or rotate the key in Google Cloud and load it at run time.", ref: "CWE-798",
                 files: .any, #"\bAIza[0-9A-Za-z_\-]{35}\b"#, skipsComments: false, masks: true),
        LineRule("secret.jwt", .secrets, .medium, "JSON Web Token in the code",
                 why: "A real token grants whatever it was issued for until it expires.",
                 fix: "Remove it; tests can mint their own tokens.", ref: "CWE-798",
                 files: .any, #"\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#, skipsComments: false, masks: true),
        LineRule("secret.password", .secrets, .high, "Hard-coded password or key",
                 why: "Credentials in code end up in every clone, fork and build log.",
                 fix: "Read the value from the environment or a secret manager, and rotate this one.", ref: "CWE-798",
                 files: .any,
                 #"(?i)\b(?:password|passwd|pwd|secret|client_?secret|api_?key|access_?token|auth_?token|private_?key)\b["']?\s*[:=]\s*["'][^"'\s$<{%]{8,}["']"#,
                 skipsComments: false, masks: true),
        LineRule("secret.connection", .secrets, .high, "Connection string with a password",
                 why: "The password in the URL opens the database to anyone who reads it.",
                 fix: "Build the URL from environment variables and rotate the password.", ref: "CWE-798",
                 files: .any, #"\b(?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis|amqps?|mssql)://[^:/\s"'\\]+:[^@/\s"'$<{\\]{3,}@"#,
                 skipsComments: false, masks: true),
    ]

    /// Values that only look like secrets.
    static let placeholders = ["example", "changeme", "change-me", "change_me", "xxxx", "your_", "your-", "<your", "dummy", "placeholder",
                               "redacted", "****", "••••", "sample", "fake", "test", "lorem", "todo", "replace", "insert", "process.env",
                               "os.environ", "getenv", "env(", "${", "{{"]

    // MARK: Code

    static let code: [LineRule] = [
        // JavaScript and TypeScript
        LineRule("js.eval", .code, .high, "eval runs a string as code",
                 why: "If any part of the string comes from a user, they can run their own code in your process or page.",
                 fix: "Parse the data (JSON.parse) or look the action up in a table instead.", ref: "CWE-95",
                 files: .extensions(js), #"(?<![\w.$])eval\s*\(|\bnew\s+Function\s*\("#),
        LineRule("js.exec", .code, .high, "Shell command built from a string",
                 why: "Values pasted into a shell command can add commands of their own (`; rm -rf ~`).",
                 fix: "Use execFile or spawn with an argument array, never a shell string.", ref: "CWE-78",
                 files: .extensions(js), #"\b(?:exec|execSync)\s*\(\s*(?:`[^`]*\$\{|["'][^"']*["']\s*\+|[A-Za-z_$][\w$]*\s*[,)])"#),
        LineRule("js.html", .code, .medium, "HTML written from a string",
                 why: "Text set as HTML runs any script it contains: cross-site scripting.",
                 fix: "Set textContent, or sanitise with DOMPurify before inserting HTML.", ref: "CWE-79",
                 files: .extensions(js), #"\.(?:inner|outer)HTML\s*\+?=(?!=)|dangerouslySetInnerHTML|\bdocument\.write\s*\(|\bv-html\s*="#),
        LineRule("js.sql", .code, .high, "SQL built from a string",
                 why: "Values pasted into SQL let a user read or change any table: SQL injection.",
                 fix: "Pass values as query parameters ($1, ?) or use the query builder's bindings.", ref: "CWE-89",
                 files: .extensions(js),
                 #"\.(?:query|execute|raw|unsafe|\$queryRawUnsafe|\$executeRawUnsafe)\s*\(\s*(?:`[^`]*\$\{|"(?i:select|insert|update|delete|with)\b[^"]*"\s*\+|'(?i:select|insert|update|delete|with)\b[^']*'\s*\+)"#),
        LineRule("js.tls", .encryption, .high, "TLS certificate checks turned off",
                 why: "Without certificate checks anyone on the network can read and change the traffic.",
                 fix: "Remove the override; for a private CA pass its certificate (ca:) instead.", ref: "CWE-295",
                 files: .extensions(js), #"rejectUnauthorized\s*:\s*false|NODE_TLS_REJECT_UNAUTHORIZED\s*[=:]\s*["']?0"#),
        LineRule("js.random", .code, .medium, "Math.random used for a secret value",
                 why: "Math.random is predictable, so tokens made with it can be guessed.",
                 fix: "Use crypto.randomUUID() or crypto.getRandomValues().", ref: "CWE-338",
                 files: .extensions(js), #"(?i)(?:token|secret|password|nonce|salt|otp|session|apikey|api_key)[^\n]*Math\.random\(\)|Math\.random\(\)[^\n]*(?:token|secret|password|nonce|salt|otp|session)"#),
        LineRule("js.cors", .code, .medium, "CORS open to every site",
                 why: "Any website can call this API from a visitor's browser.",
                 fix: "List the origins that may call it.", ref: "CWE-942",
                 files: .extensions(js), #"\borigin\s*:\s*(?:["']\*["']|true)\b|Access-Control-Allow-Origin["']?\s*[,:]\s*["']\*"#),
        LineRule("js.jwt-none", .code, .critical, "JWTs accepted without a signature",
                 why: "With the \"none\" algorithm anyone can forge a token and log in as anyone.",
                 fix: "Allow only the algorithm you sign with, such as HS256 or RS256.", ref: "CWE-347",
                 files: .extensions(js), #"algorithms?\s*:\s*\[?\s*["']none["']"#),
        LineRule("js.jwt-decode", .code, .medium, "JWT read without checking its signature",
                 why: "jwt.decode trusts whatever the token says; use it for display only.",
                 fix: "Use jwt.verify with your key before trusting the claims.", ref: "CWE-345",
                 files: .extensions(js), #"\bjwt\.decode\s*\("#),

        // Python
        LineRule("py.shell", .code, .high, "Command run through the shell",
                 why: "With shell=True, values in the command can add commands of their own.",
                 fix: "Pass a list of arguments and drop shell=True.", ref: "CWE-78",
                 files: .extensions(python), #"\bshell\s*=\s*True\b"#),
        LineRule("py.system", .code, .medium, "os.system runs a shell command",
                 why: "Values in the command string can add commands of their own.",
                 fix: "Use subprocess.run with a list of arguments.", ref: "CWE-78",
                 files: .extensions(python), #"\bos\.(?:system|popen)\s*\("#),
        LineRule("py.eval", .code, .high, "eval or exec runs a string as code",
                 why: "If any part of the string comes from outside, it can run anything.",
                 fix: "Use ast.literal_eval for data, or a lookup table for actions.", ref: "CWE-95",
                 files: .extensions(python), #"(?<![\w.])(?:eval|exec)\s*\("#),
        LineRule("py.pickle", .code, .high, "Unpickling data",
                 why: "Unpickling untrusted bytes runs code chosen by whoever made them.",
                 fix: "Use JSON or another data-only format for anything that crosses a boundary.", ref: "CWE-502",
                 files: .extensions(python), #"\b(?:c?[Pp]ickle|dill|marshal|shelve)\.(?:loads?|open)\s*\("#),
        LineRule("py.yaml", .code, .high, "yaml.load without a safe loader",
                 why: "yaml.load can build any Python object, which runs code.",
                 fix: "Use yaml.safe_load.", ref: "CWE-502",
                 files: .extensions(python), #"\byaml\.(?:load|load_all|unsafe_load)\s*\("#, unless: #"SafeLoader|CSafeLoader|BaseLoader"#),
        LineRule("py.sql", .code, .high, "SQL built from a string",
                 why: "Values formatted into SQL let a user read or change any table: SQL injection.",
                 fix: "Pass values as parameters: cursor.execute(\"… WHERE id = %s\", (id,)).", ref: "CWE-89",
                 files: .extensions(python), #"\.(?:execute|executemany|raw|text)\s*\(\s*(?:f["']|"[^"]*"\s*(?:%|\.format\s*\(|\+)|'[^']*'\s*(?:%|\.format\s*\(|\+))"#),
        LineRule("py.tls", .encryption, .high, "TLS certificate checks turned off",
                 why: "Without certificate checks anyone on the network can read and change the traffic.",
                 fix: "Remove verify=False; pass the CA bundle for a private CA.", ref: "CWE-295",
                 files: .extensions(python), #"\bverify\s*=\s*False\b|ssl\._create_unverified_context|CERT_NONE"#),
        LineRule("py.debug", .code, .medium, "Debug mode on",
                 why: "Debug pages show code and settings, and Werkzeug's debugger runs any code it's sent.",
                 fix: "Read debug from the environment and keep it off in production.", ref: "CWE-489",
                 files: .extensions(python), #"\.run\([^)]*\bdebug\s*=\s*True|^\s*DEBUG\s*=\s*True\b"#),
        LineRule("py.hash", .encryption, .low, "MD5 or SHA-1",
                 why: "Both are broken for anything security-related, such as passwords or signatures.",
                 fix: "Use hashlib.sha256 for checksums and bcrypt, scrypt or argon2 for passwords.", ref: "CWE-328",
                 files: .extensions(python), #"\bhashlib\.(?:md5|sha1)\s*\("#, unless: #"usedforsecurity\s*=\s*False"#),
        LineRule("py.tempfile", .code, .low, "tempfile.mktemp",
                 why: "Another process can create the file between naming it and opening it.",
                 fix: "Use tempfile.NamedTemporaryFile or mkstemp.", ref: "CWE-377",
                 files: .extensions(python), #"\btempfile\.mktemp\s*\("#),

        // Go
        LineRule("go.sql", .code, .high, "SQL built from a string",
                 why: "Values formatted into SQL let a user read or change any table: SQL injection.",
                 fix: "Use placeholders ($1, ?) and pass the values as arguments.", ref: "CWE-89",
                 files: .extensions(go), #"\.(?:Query|QueryRow|Exec|Prepare)(?:Context)?\s*\((?:[^()]*,\s*)?(?:fmt\.Sprintf\s*\(|"[^"]*"\s*\+)"#),
        LineRule("go.tls", .encryption, .high, "TLS certificate checks turned off",
                 why: "Without certificate checks anyone on the network can read and change the traffic.",
                 fix: "Remove InsecureSkipVerify; add a private CA to RootCAs instead.", ref: "CWE-295",
                 files: .extensions(go), #"InsecureSkipVerify\s*:\s*true"#),
        LineRule("go.shell", .code, .medium, "Command run through a shell",
                 why: "Values in the script can add commands of their own.",
                 fix: "Run the program directly with exec.Command(name, args...).", ref: "CWE-78",
                 files: .extensions(go), #"exec\.Command(?:Context)?\(\s*(?:ctx,\s*)?"(?:/bin/)?(?:sh|bash|zsh)"\s*,\s*"-c""#),
        LineRule("go.hash", .encryption, .low, "MD5 or SHA-1",
                 why: "Both are broken for anything security-related.",
                 fix: "Use sha256 for checksums and bcrypt or argon2 for passwords.", ref: "CWE-328",
                 files: .extensions(go), #"\b(?:md5|sha1)\.(?:New|Sum)\s*\("#),

        // Other languages
        LineRule("php.exec", .code, .high, "Code or shell run from a string",
                 why: "Values in the string can run code or commands of their own.",
                 fix: "Avoid eval; use escapeshellarg or proc_open with an argument array.", ref: "CWE-78",
                 files: .extensions(["php"]), #"(?<![\w>:$])(?:eval|system|exec|shell_exec|passthru|popen)\s*\("#),
        LineRule("java.exec", .code, .medium, "Runtime.exec",
                 why: "A command string is split on spaces and can be steered by its values.",
                 fix: "Use ProcessBuilder with a list of arguments.", ref: "CWE-78",
                 files: .extensions(["java", "kt", "scala"]), #"Runtime\.getRuntime\(\)\.exec\s*\("#),
        LineRule("swift.defaults", .privacy, .medium, "Secret kept in UserDefaults",
                 why: "UserDefaults is a plain file anyone with the Mac or a backup can read.",
                 fix: "Keep passwords and tokens in the Keychain.", ref: "CWE-312",
                 files: .extensions(["swift", "m"]), #"(?i)(?:UserDefaults|NSUserDefaults)[^\n]*set[^\n]*(?:password|token|secret|apikey|api_key)"#),
        LineRule("swift.ats", .encryption, .medium, "App Transport Security turned off",
                 why: "The app may load anything over plain HTTP.",
                 fix: "Remove NSAllowsArbitraryLoads and add exceptions for the hosts that need them.", ref: "CWE-319",
                 files: .kind(.plist), #"NSAllowsArbitraryLoads</key>\s*$|NSAllowsArbitraryLoads"#, skipsComments: false),
        LineRule("shell.pipe", .code, .medium, "Script downloaded and run in one go",
                 why: "Whatever the server sends runs with your permissions, with nothing checked first.",
                 fix: "Download it, check its checksum or signature, then run it.", ref: "CWE-494",
                 files: .extensions(shell.union(["dockerfile", "yml", "yaml"])), #"\b(?:curl|wget)\b[^|\n]*\|\s*(?:sudo\s+)?(?:ba|z)?sh\b"#),
        LineRule("shell.chmod", .code, .medium, "World-writable permissions",
                 why: "Any user or process on the machine can change these files.",
                 fix: "Grant only what's needed, such as 755 or 644.", ref: "CWE-732",
                 files: .extensions(shell.union(["dockerfile", "yml", "yaml"])), #"\bchmod\s+(?:-R\s+)?0?777\b"#),
    ]

    static let sqlHosts: Set<String> = ["java", "kt", "scala", "cs", "php", "rb", "rs", "swift", "dart"]
    static let server: Set<String> = js.union(python).union(go).union(sqlHosts)

    /// Personal information (POPIA, GDPR): where it leaks, and where it should be encrypted.
    static let privacy: [LineRule] = [
        LineRule("pii.log", .privacy, .medium, "Personal information written to logs",
                 why: "Logs are copied to many places and kept for a long time; POPIA's security safeguards (section 19) cover them too.",
                 fix: "Log an id or a masked value instead (j***@example.com, ******7083).", ref: "CWE-532",
                 files: .extensions(server),
                 #"(?i)\b(?:console\.(?:log|info|debug|warn|error)|log(?:ger)?\.(?:print|info|debug|warn|warning|error|trace)\w*|print|println|printf|fmt\.Print\w*|slog\.\w+|NSLog|Log\.\w)\s*\([^)\n]*\b(?:id_?number|id_?no|national_?id|identity_?number|passport|ssn|social_?security|tax_?(?:number|no|id)|card_?number|cc_?number|cvv|cvc|bank_?account|account_?number|iban|date_?of_?birth|dob|medical|diagnosis|health|password|passwd)\b"#),
        LineRule("pii.request-log", .privacy, .medium, "Whole request bodies written to logs",
                 why: "Request bodies carry whatever people type: names, ID numbers, passwords.",
                 fix: "Log the route, status and a request id, not the body.", ref: "CWE-532",
                 files: .extensions(server),
                 #"(?i)\b(?:console\.(?:log|info|debug)|log(?:ger)?\.(?:info|debug|print)\w*|print)\s*\([^)\n]*\b(?:req|request)\.(?:body|json|form|data|POST)\b"#),
        LineRule("pii.error-leak", .privacy, .medium, "Error details sent to the client",
                 why: "Stack traces and raw errors show file paths, queries and sometimes data to whoever triggers them.",
                 fix: "Log the error on the server and send a generic message with a reference id.", ref: "CWE-209",
                 files: .extensions(server),
                 #"(?i)\.(?:send|json|write|end)\s*\(\s*(?:err|error|e|ex)(?:\.stack|\.message)?\s*\)|res\.status\(\s*500\s*\)\.(?:send|json)\(\s*(?:err|error|e)\b|traceback\.format_exc\(\)|http\.Error\([^,]+,\s*err\.Error\(\)"#),
        LineRule("pii.cookie", .privacy, .medium, "Cookie without Secure or HttpOnly",
                 why: "Session cookies without these flags can be read by scripts or sent over plain HTTP.",
                 fix: "Set secure: true, httpOnly: true and sameSite on session cookies.", ref: "CWE-614",
                 files: .extensions(server), #"(?i)\b(?:secure|httpOnly|http_only|SESSION_COOKIE_SECURE|SESSION_COOKIE_HTTPONLY|CSRF_COOKIE_SECURE)\s*[:=]\s*(?:false|False)\b"#),
        LineRule("pii.local-storage", .privacy, .medium, "Sensitive data kept in localStorage",
                 why: "Any script on the page can read localStorage, so one XSS bug leaks every token in it.",
                 fix: "Keep session tokens in HttpOnly cookies.", ref: "CWE-922",
                 files: .extensions(js), #"(?i)localStorage\.setItem\(\s*["'][^"']*(?:token|jwt|session|password|secret|auth)[^"']*["']"#),
        LineRule("pii.plain-column", .privacy, .medium, "Sensitive data stored as plain text",
                 why: "ID numbers, bank details and health data should be encrypted at rest; POPIA requires reasonable safeguards, and a leaked table is a reportable breach (section 22).",
                 fix: "Encrypt the column (pgcrypto, application-level AES-GCM, or a KMS), or store a hash when you only need to compare.", ref: "CWE-311",
                 files: .extensions(["sql", "prisma"]),
                 #"(?i)^\s*["`]?(?:id_?number|national_?id|identity_?number|passport_?(?:number|no)?|ssn|tax_?(?:number|no)|card_?number|cc_?number|bank_?account(?:_?number)?|account_?number|iban|medical_?\w*|diagnosis|health_?\w*|biometric\w*)["`]?\s+(?:varchar|text|char|nvarchar|string|integer|bigint|numeric|int)\b"#,
                 unless: #"(?i)encrypt|cipher|hash|digest|bytea|_enc\b|masked"#),
        LineRule("pii.password-column", .privacy, .high, "Password stored as plain text",
                 why: "Plain passwords leak every account at once, and people reuse them elsewhere.",
                 fix: "Store a bcrypt, scrypt or argon2 hash in a password_hash column.", ref: "CWE-256",
                 files: .extensions(["sql", "prisma"]), #"(?i)^\s*["`]?password["`]?\s+(?:varchar|text|char|nvarchar|string)\b"#),
    ]

    /// Encryption in transit and at rest.
    static let encryption: [LineRule] = [
        LineRule("crypto.http", .encryption, .medium, "Plain HTTP to another server",
                 why: "Anything sent over http:// can be read and changed on the way, including personal information and tokens.",
                 fix: "Use https://.", ref: "CWE-319",
                 files: .extensions(server.union(["env", "yml", "yaml", "json", "toml"])),
                 #"["'=]\s*http://(?!localhost|127\.|0\.0\.0\.0|\[::1\]|10\.|192\.168\.|172\.(?:1[6-9]|2\d|3[01])\.|[\w.-]*\.local\b|[\w.-]*\.test\b|[\w.-]*\.internal\b|host\.docker\.internal|example\.(?:com|org)|www\.w3\.org|schemas?\.|xmlns|json-schema\.org|purl\.org|ns\.adobe|www\.apache\.org)[\w.-]+"#),
        LineRule("crypto.weak-cipher", .encryption, .high, "Weak or broken cipher",
                 why: "ECB, DES, 3DES and RC4 can be broken or leak patterns in the data; createCipher derives a weak key and no IV.",
                 fix: "Use AES-256-GCM (or ChaCha20-Poly1305) with a random IV per message.", ref: "CWE-327",
                 files: .extensions(server),
                 #"(?i)\bcreateCipher\s*\(|["']aes-\d+-ecb["']|AES/ECB|MODE_ECB|\bDES(?:ede)?\b[^\n]*(?:Cipher|new|create)|\bdes-(?:ede3?|cbc)|\bRC4\b|\barc4\b|Cipher\.getInstance\(\s*"AES"\s*\)"#),
        LineRule("crypto.static-iv", .encryption, .medium, "Fixed IV or salt",
                 why: "A constant IV or salt makes equal inputs encrypt or hash the same, which leaks data.",
                 fix: "Generate a random IV or salt for every message and store it alongside.", ref: "CWE-329",
                 files: .extensions(server), #"(?i)\b(?:iv|nonce|salt)\s*[:=]\s*(?:b?["'][^"'\n]{4,}["']|Buffer\.from\(\s*["']|bytes\(\s*["'])"#),
        LineRule("crypto.password-hash", .encryption, .high, "Passwords hashed with a fast hash",
                 why: "MD5 and SHA hashes of passwords are cracked by the billion per second.",
                 fix: "Use bcrypt, scrypt or argon2.", ref: "CWE-916",
                 files: .extensions(server), #"(?i)(?:md5|sha1|sha256|sha512)\w*\([^)\n]*password|password[^\n]*(?:md5|sha1|sha256|sha512)\s*\("#),
    ]

    /// SQL built from strings in languages without their own rule.
    static let sql: [LineRule] = [
        LineRule("sql.concat", .code, .high, "SQL built from a string",
                 why: "Values pasted into SQL let a user read or change any table: SQL injection.",
                 fix: "Use a prepared statement and bind the values as parameters.", ref: "CWE-89",
                 files: .extensions(sqlHosts),
                 #""(?i:\s*(?:select\s[^"]*\sfrom|insert\s+into|update\s+\w+\s+set|delete\s+from)\b)[^"]*"\s*(?:\+|\.|&|<<)\s*[\w$(]|'(?i:\s*(?:select\s[^']*\sfrom|insert\s+into|update\s+\w+\s+set|delete\s+from)\b)[^']*'\s*(?:\+|\.|&|<<)\s*[\w$(]|(?:mysqli?_query|->query|pg_query)\s*\([^)\n]*["'][^"'\n]*\$\w+"#),
    ]

    // MARK: Containers, pipelines and infrastructure

    static let config: [LineRule] = [
        LineRule("docker.add-url", .containers, .medium, "ADD fetches a URL",
                 why: "ADD downloads without any check, and the file changes under you.",
                 fix: "Use curl with a pinned checksum in a RUN step, or COPY a vendored file.", ref: "CWE-494",
                 files: .kind(.dockerfile), #"^\s*ADD\s+https?://"#),
        LineRule("docker.secret", .containers, .high, "Secret baked into the image",
                 why: "ENV and ARG values are stored in the image's layers and history for anyone who pulls it.",
                 fix: "Use build secrets (RUN --mount=type=secret) and runtime environment variables.", ref: "CWE-798",
                 files: .kind(.dockerfile), #"^\s*(?:ENV|ARG)\s+\w*(?:PASSWORD|PASSWD|SECRET|TOKEN|API_KEY|APIKEY|PRIVATE_KEY|ACCESS_KEY)\w*(?:\s*=\s*|\s+)\S+"#),
        LineRule("compose.privileged", .containers, .high, "Privileged container",
                 why: "A privileged container can take over the host.",
                 fix: "Drop privileged and add only the capabilities it needs (cap_add).", ref: "CWE-250",
                 files: .kind(.compose), #"^\s*privileged\s*:\s*true\b"#),
        LineRule("compose.socket", .containers, .high, "Docker socket mounted",
                 why: "Access to the Docker socket is root on the host.",
                 fix: "Remove the mount, or put a socket proxy with read-only rules in between.", ref: "CWE-250",
                 files: .kind(.compose), #"/var/run/docker\.sock"#),
        LineRule("compose.host-network", .containers, .medium, "Host networking",
                 why: "The container shares the host's network and can reach everything it can.",
                 fix: "Use a bridge network and publish only the ports it needs.", ref: "CWE-653",
                 files: .kind(.compose), #"^\s*network_mode\s*:\s*["']?host"#),
        LineRule("compose.db-port", .containers, .medium, "Database port open to the network",
                 why: "Publishing a database port on every interface lets anyone on the network try to log in.",
                 fix: "Bind it to this Mac only: \"127.0.0.1:5432:5432\", or don't publish it.", ref: "CWE-668",
                 files: .kind(.compose), #"^\s*-\s*["']?(?:0\.0\.0\.0:)?(?:5432|3306|27017|6379|9200|11211|5984|9042|1433)\s*:\s*\d+"#),
        LineRule("compose.default-password", .containers, .medium, "Default database password",
                 why: "Well-known passwords are the first thing anyone tries.",
                 fix: "Use a generated password from an ignored .env file.", ref: "CWE-1393",
                 files: .kind(.compose),
                 #"(?i)(?:POSTGRES|MYSQL|MYSQL_ROOT|MARIADB_ROOT|MONGO_INITDB_ROOT|REDIS|RABBITMQ_DEFAULT)_PASS(?:WORD)?\s*[:=]\s*["']?(?:postgres|password|root|admin|example|secret|changeme|123456|guest)["']?\s*$"#),
        LineRule("k8s.privileged", .containers, .high, "Privileged or root container",
                 why: "A privileged or root container can escape to the node.",
                 fix: "Set privileged: false, runAsNonRoot: true and allowPrivilegeEscalation: false.", ref: "CWE-250",
                 files: .kind(.kubernetes), #"^\s*(?:privileged\s*:\s*true|allowPrivilegeEscalation\s*:\s*true|runAsUser\s*:\s*0\b|hostNetwork\s*:\s*true|hostPID\s*:\s*true)"#),
        LineRule("gha.injection", .pipelines, .high, "Untrusted text in a workflow script",
                 why: "Titles, branch names and comments are written by whoever opens the PR or issue; in a run step they become shell commands.",
                 fix: "Pass the value through env: and quote it as \"$VALUE\" in the script.", ref: "CWE-94",
                 files: .kind(.workflow),
                 #"\$\{\{\s*github\.(?:event\.(?:issue|pull_request|comment|review|review_comment|head_commit|commits|pages|discussion)[^}]*\.(?:title|body|message|name|ref|label|email|default_branch)|head_ref)\s*\}\}"#),
        LineRule("gha.write-all", .pipelines, .medium, "Workflow can write everything",
                 why: "A compromised step could push code, publish packages and change settings.",
                 fix: "Grant only what each job needs, such as contents: read.", ref: "CWE-250",
                 files: .kind(.workflow), #"^\s*permissions\s*:\s*write-all"#),
        LineRule("gha.unpinned", .pipelines, .low, "Third-party action not pinned",
                 why: "A tag can be moved to new code at any time, which then runs with your secrets.",
                 fix: "Pin the action to a full commit SHA (with the tag in a comment).", ref: "CWE-829",
                 files: .kind(.workflow), #"^\s*-?\s*uses\s*:\s*(?!actions/|github/|\./|docker://)[\w.-]+/[\w./-]+@(?![0-9a-f]{40}\b)"#),
        LineRule("tf.open", .infrastructure, .medium, "Open to the whole internet",
                 why: "0.0.0.0/0 lets any address reach this port.",
                 fix: "Limit the CIDR to your office, VPN or load balancer.", ref: "CWE-284",
                 files: .kind(.terraform), #"(?:cidr_blocks|cidr_ipv4|source_ranges|cidr_block)\s*=\s*\[?\s*"(?:0\.0\.0\.0/0|::/0)""#),
        LineRule("tf.public-acl", .infrastructure, .high, "Public bucket",
                 why: "Anyone can list or read what's in it.",
                 fix: "Make it private and add a public access block.", ref: "CWE-284",
                 files: .kind(.terraform), #"acl\s*=\s*"public-read(?:-write)?""#),
        LineRule("tf.public-db", .infrastructure, .high, "Database reachable from the internet",
                 why: "A public database is scanned and attacked within hours.",
                 fix: "Set publicly_accessible = false and reach it through a private network.", ref: "CWE-284",
                 files: .kind(.terraform), #"publicly_accessible\s*=\s*true"#),
        LineRule("tf.unencrypted", .encryption, .medium, "Storage not encrypted",
                 why: "Data at rest is readable by anyone who gets the disk or snapshot.",
                 fix: "Turn encryption on (encrypted = true, storage_encrypted = true).", ref: "CWE-311",
                 files: .kind(.terraform), #"\b(?:encrypted|storage_encrypted|encrypt_at_rest)\s*=\s*false"#),
        LineRule("tf.iam-star", .infrastructure, .high, "IAM policy allows every action",
                 why: "Whoever holds this role can do anything in the account.",
                 fix: "List the actions and resources it needs.", ref: "CWE-250",
                 files: .any, #"["']?Action["']?\s*[:=]\s*\[?\s*["']\*["']|actions\s*=\s*\[\s*"\*"\s*\]"#),
    ]

    static let all = secrets + privacy + encryption + code + sql + config
}
