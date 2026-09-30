# Rewriting old paths into new ones, inside files and inside strings.
#
# The work is done by a small C# class compiled at load time. PowerShell 7
# ships the compiler, so this adds no dependency, and it matters: the
# transcript corpus runs to gigabytes, and the rewrite has to be exact in ways
# a line-by-line PowerShell loop was not — it normalised every line ending to
# CRLF, re-encoded lines it never changed, and could not tell a text line from
# a binary one.

if (-not ('ClaudExt.PathRemapper' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

namespace ClaudExt
{
    public sealed class RemapFileResult
    {
        public long LinesChanged;
        public long Replacements;
        public long LinesKeptAsBytes;
        public long LinesLeftStale;
    }

    public sealed class PathRemapper
    {
        // A path segment continues with any of these; anything else ends it.
        // Combining marks included: an NFD 'á' is 'a' plus a mark.
        private const string NameChar = @"[\p{L}\p{M}\p{N}_.\-~]";
        private static readonly UTF8Encoding Strict = new UTF8Encoding(false, true);
        private static readonly UTF8Encoding Plain = new UTF8Encoding(false, false);
        private static readonly Encoding Latin1 = Encoding.GetEncoding(28591);
        // This machine's legacy code page (1254 on a Turkish Windows), which
        // scripts saved by older editors use. Null when there is none to use.
        private static readonly Encoding Ansi = GetAnsi();

        // Two matchers over the same forms. Text files see every form. JSON
        // files see only the escaped and the forward-slash ones: in valid JSON
        // a lone backslash always starts an escape, so a raw 'D:\' there is
        // never a path — it is 'D:' followed by '\n' or '\"', and rewriting it
        // would break the line.
        private readonly Regex _text;
        private readonly Regex _json;
        private readonly int[] _textIndex;
        private readonly int[] _jsonIndex;

        private readonly string[] _targets;
        private readonly int[] _shared;
        private readonly int[] _lengths;
        private readonly bool[] _ascii;
        private readonly bool[] _ansi;
        private readonly MatchEvaluator _evaluator;
        private long _replacements;

        // Set around each Replace: which group is which form, which forms may
        // be written in the encoding at hand, and whether one was held back.
        private int[] _index;
        private bool[] _allowed;
        private bool _heldBack;

        public int FormCount { get { return _targets.Length; } }

        private sealed class Form
        {
            public string Text;
            public string Target;
            public bool IgnoreCase;
            public bool Escaped;
            public int Order;
            public string Tail;
        }

        public PathRemapper(string[] froms, string[] tos)
        {
            if (froms == null || tos == null || froms.Length != tos.Length)
                throw new ArgumentException("froms and tos must be arrays of the same length");

            var forms = new List<Form>();
            var seen = new HashSet<string>(StringComparer.Ordinal);

            Action<string, string, bool, bool> add = (text, target, ignoreCase, escaped) =>
            {
                string key = (ignoreCase ? "i:" + text.ToLowerInvariant() : "s:" + text);
                if (text.Length == 0 || !seen.Add(key)) return;
                forms.Add(new Form { Text = text, Target = target, IgnoreCase = ignoreCase, Escaped = escaped, Order = forms.Count });
            };

            for (int i = 0; i < froms.Length; i++)
            {
                string from = TrimPath(froms[i] ?? "");
                string to = TrimPath(tos[i] ?? "");
                // A filesystem root on its own would match every path on it.
                if (from.Length == 0 || from == "/" || from == "\\") continue;
                // An entry that maps a path to itself is kept on purpose: it is
                // how a project someone chose to leave where it was is shielded
                // from a shorter entry that would otherwise move it along with
                // its parent. Longest first, it wins, and rewrites to itself.

                bool windows = IsWindowsStyle(from);
                if (from.IndexOf('\\') >= 0)
                {
                    // The three forms a path takes across Claude's files:
                    // JSON-escaped inside records, raw in text, and with forward
                    // slashes in some config values.
                    add(from.Replace("\\", "\\\\"), to.Replace("\\", "\\\\"), windows, true);
                    add(from, to, windows, false);
                    add(from.Replace('\\', '/'), to.Replace('\\', '/'), windows, false);
                }
                else
                {
                    // A path with no backslash: POSIX, or Windows already
                    // written with forward slashes. A Windows target is written
                    // with forward slashes too, which is valid in a JSON string
                    // and in plain text alike, so nothing is ever half-escaped.
                    add(from, IsWindowsStyle(to) ? to.Replace('\\', '/') : to, windows, false);
                }
            }

            // Where a match may end, which depends on whether either side is a
            // drive root ('D:\', the only root that reaches here).
            var all = new List<Form>();
            foreach (Form f in forms)
            {
                char last = f.Text[f.Text.Length - 1];
                bool fromRoot = last == '\\' || last == '/';
                char targetLast = f.Target.Length > 0 ? f.Target[f.Target.Length - 1] : '\0';
                bool toRoot = targetLast == '\\' || targetLast == '/';
                // Anything that cannot continue a name ends a path, and a full
                // stop does too where a sentence ends: before a space, a quote,
                // a bracket, an escape or the end of the line.
                // 'cd C:\\x\\proj && npm test' ends at the space.
                string end = "(?:(?!" + NameChar + @")|(?=\.(?:[\s""'`\\)\]},;]|$)))";

                if (fromRoot && toRoot)
                {
                    // Root to root: whatever follows is the rest of the path.
                    f.Tail = "";
                    all.Add(f);
                }
                else if (fromRoot)
                {
                    // 'D:\' to 'F:\gamma': a path that goes on needs the
                    // separator the root carried ('D:\Work' is 'F:\gamma\Work');
                    // the root on its own does not ('F:\gamma', not 'F:\gamma\').
                    string alone = @"(?:[\s""'`,;|<>*?)\]}]|$)";
                    string separator = f.Target.IndexOf('\\') >= 0 ? (f.Escaped ? "\\\\" : "\\") : "/";
                    all.Add(new Form { Text = f.Text, Target = f.Target + separator, IgnoreCase = f.IgnoreCase, Escaped = f.Escaped, Order = f.Order, Tail = "(?!" + alone + ")" });
                    f.Tail = "(?=" + alone + ")";
                    all.Add(f);
                }
                else if (toRoot)
                {
                    // 'G:\app' to 'E:\': the separator after the old path goes
                    // with it, so 'G:\app\src' becomes 'E:\src', not 'E:\\src'.
                    string separator = f.Escaped ? @"(?:\\\\|/)" : @"[\\/]";
                    f.Tail = "(?:" + separator + "|" + end + ")";
                    all.Add(f);
                }
                else
                {
                    f.Tail = end;
                    all.Add(f);
                }
            }
            forms = all;

            // Longest first, so a specific mapping wins over a shorter one that
            // shares its head. Everything is matched in one pass, so a path
            // already rewritten is never rewritten again by a later entry.
            forms.Sort((a, b) =>
            {
                int byLength = b.Text.Length.CompareTo(a.Text.Length);
                return byLength != 0 ? byLength : a.Order.CompareTo(b.Order);
            });

            int n = forms.Count;
            _targets = new string[n];
            _shared = new int[n];
            _lengths = new int[n];
            _ascii = new bool[n];
            _ansi = new bool[n];
            var textParts = new List<string>();
            var jsonParts = new List<string>();
            var textIndex = new List<int>();
            var jsonIndex = new List<int>();
            for (int k = 0; k < n; k++)
            {
                Form f = forms[k];
                string escaped = Regex.Escape(f.Text);
                string part = "(" + (f.IgnoreCase ? "(?i:" + escaped + ")" : escaped) + f.Tail + ")";
                textParts.Add(part);
                textIndex.Add(k);
                if (f.Escaped || f.Text.IndexOf('\\') < 0)
                {
                    jsonParts.Add(part);
                    jsonIndex.Add(k);
                }

                _lengths[k] = f.Text.Length;
                _targets[k] = f.Target;
                _shared[k] = SharedPrefix(f.Text, f.Target, f.IgnoreCase);
                _ascii[k] = IsAscii(f.Text) && IsAscii(f.Target);
                _ansi[k] = Ansi != null && RoundTrips(Ansi, f.Text) && RoundTrips(Ansi, f.Target);
            }
            _textIndex = textIndex.ToArray();
            _jsonIndex = jsonIndex.ToArray();

            // A boundary before the path too: '/home/ada' must not rewrite
            // '/other/home/ada', and a path does not start right after a
            // separator either, so 'D:\' leaves the 'd:\' inside a pattern like
            // '\d\d:\d\d' alone. Inside a JSON string a path often follows an
            // escaped newline or tab ("...:\nC:\\..."), and the letter of that
            // escape is not part of a name; a file URI and a '\\?\' long-path
            // prefix end in separators and are let through. Case-insensitive
            // parts are scoped inline, so a POSIX path stays case-sensitive.
            // A colour code in saved terminal output ('ESC[36m') ends in a
            // letter too, and a path after it is still a path. So is a drive
            // path after a single slash ('/C:/Users/...', how some tools write
            // a Windows path as a URL path) or after a scheme ('unix://C:\...').
            string before = @"(?:(?<=\\[nrtbf])|(?<=(?i:file)://)|(?<=(?i:file):///)|(?<=[\\/]{2,4}[?.][\\/]{1,2})" +
                            @"|(?<=\[[0-9;]{1,12}m)" +
                            @"|(?<=(?<![\p{L}\p{M}\p{N}_.\-~\\/])/)(?=[A-Za-z]:)" +
                            @"|(?<=[A-Za-z][A-Za-z0-9+.\-]*://)(?=[A-Za-z]:)" +
                            @"|(?<![\p{L}\p{M}\p{N}_.\-~\\/]))";
            var options = RegexOptions.CultureInvariant | RegexOptions.Compiled;
            _text = textParts.Count == 0 ? null : new Regex(before + "(?:" + string.Join("|", textParts) + ")", options);
            _json = jsonParts.Count == 0 ? null : new Regex(before + "(?:" + string.Join("|", jsonParts) + ")", options);
            _evaluator = Evaluate;
        }

        public long Replacements { get { return _replacements; } }

        private static Encoding GetAnsi()
        {
            try
            {
                int cp = CultureInfo.CurrentCulture.TextInfo.ANSICodePage;
                if (cp <= 0 || cp == 65001 || cp == 28591) return null;
                Encoding e = Encoding.GetEncoding(cp, EncoderFallback.ExceptionFallback, DecoderFallback.ExceptionFallback);
                return e.IsSingleByte ? e : null;
            }
            catch { return null; }
        }

        private static bool RoundTrips(Encoding e, string s)
        {
            try { return string.Equals(e.GetString(e.GetBytes(s)), s, StringComparison.Ordinal); }
            catch { return false; }
        }

        // The part of the target it shares with the source keeps the spelling
        // it was found in: 'c:\users\old' becomes 'c:\users\new', not
        // 'C:\Users\new'. In ~/.claude.json and history.jsonl the path is a
        // lookup key, and a lowercase-drive key has to stay one. Cut back to a
        // separator so no folder name ends up half one spelling and half the
        // other; a path mapped to itself is left exactly as found.
        private static int SharedPrefix(string from, string to, bool ignoreCase)
        {
            var comparison = ignoreCase ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
            if (string.Equals(from, to, comparison)) return from.Length;
            int n = Math.Min(from.Length, to.Length);
            int i = 0;
            while (i < n && string.Compare(from, i, to, i, 1, comparison) == 0) i++;
            int cut = 0;
            for (int j = 0; j < i; j++)
            {
                if (from[j] == '\\' || from[j] == '/') cut = j + 1;
            }
            return cut;
        }

        private static bool IsAscii(string s)
        {
            foreach (char c in s) if (c > 127) return false;
            return true;
        }

        private static string TrimPath(string path)
        {
            if (path.Length == 0) return path;
            if (Regex.IsMatch(path, @"^[A-Za-z]:[\\/]*$"))
                return path.Substring(0, 2) + (path.IndexOf('/') >= 0 && path.IndexOf('\\') < 0 ? "/" : "\\");
            if (Regex.IsMatch(path, @"^[\\/]+$")) return path.Substring(0, 1);
            return path.TrimEnd('\\', '/');
        }

        private string Evaluate(Match m)
        {
            GroupCollection groups = m.Groups;
            for (int g = 1; g < groups.Count; g++)
            {
                if (!groups[g].Success) continue;
                int k = _index[g - 1];
                // A path this line's encoding cannot spell is left as it was,
                // and the line is counted as holding a stale path.
                if (_allowed != null && !_allowed[k]) { _heldBack = true; return m.Value; }
                _replacements++;
                // A separator matched past the old path is one a root target
                // already ends with; it is dropped with the old path.
                string found = groups[g].Value.Substring(0, _lengths[k]);
                return found.Substring(0, _shared[k]) + _targets[k].Substring(_shared[k]);
            }
            return m.Value;
        }

        private string Apply(Regex regex, int[] index, bool[] allowed, string text)
        {
            _index = index;
            _allowed = allowed;
            _heldBack = false;
            return regex.Replace(text, _evaluator);
        }

        public static bool IsWindowsStyle(string path)
        {
            if (string.IsNullOrEmpty(path)) return false;
            if (path.StartsWith("\\\\")) return true;
            return path.Length >= 2 && path[1] == ':' && char.IsLetter(path[0]) &&
                   (path.Length == 2 || path[2] == '\\' || path[2] == '/');
        }

        // For a string that holds paths as they are — a value already read out
        // of JSON, a line of plain text.
        public string RemapString(string text)
        {
            return RemapString(text, false);
        }

        // json: the string is JSON text, where paths appear only escaped.
        public string RemapString(string text, bool json)
        {
            Regex regex = json ? _json : _text;
            if (regex == null || string.IsNullOrEmpty(text)) return text;
            return Apply(regex, json ? _jsonIndex : _textIndex, null, text);
        }

        public RemapFileResult RemapFile(string input, string output)
        {
            return RemapFile(input, output, false);
        }

        // Streams a file through the mapping. Lines are split on the LF byte,
        // which never occurs inside a multi-byte UTF-8 sequence, and keep their
        // own terminators. A line the mapping does not touch is written back as
        // the exact bytes it was read as. json: the file is JSON or JSON Lines,
        // where paths only ever appear escaped.
        public RemapFileResult RemapFile(string input, string output, bool json)
        {
            var result = new RemapFileResult();
            long before = _replacements;
            var buffer = new byte[1 << 20];
            var pending = new MemoryStream();
            Regex regex = json ? _json : _text;
            int[] index = json ? _jsonIndex : _textIndex;

            using (var source = new FileStream(input, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1 << 16))
            using (var target = new FileStream(output, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16))
            {
                int read;
                while ((read = source.Read(buffer, 0, buffer.Length)) > 0)
                {
                    int start = 0;
                    while (start < read)
                    {
                        int newline = Array.IndexOf(buffer, (byte)'\n', start, read - start);
                        if (newline < 0)
                        {
                            pending.Write(buffer, start, read - start);
                            break;
                        }
                        int length = newline - start + 1;
                        if (pending.Length > 0)
                        {
                            pending.Write(buffer, start, length);
                            WriteLine(regex, index, pending.GetBuffer(), 0, (int)pending.Length, target, result);
                            pending.SetLength(0);
                        }
                        else
                        {
                            WriteLine(regex, index, buffer, start, length, target, result);
                        }
                        start = newline + 1;
                    }
                }
                if (pending.Length > 0) WriteLine(regex, index, pending.GetBuffer(), 0, (int)pending.Length, target, result);
            }

            // Claude Code orders past sessions by when their file last changed.
            // A rewrite must not make every session look new.
            File.SetLastWriteTimeUtc(output, File.GetLastWriteTimeUtc(input));
            result.Replacements = _replacements - before;
            return result;
        }

        private static bool SameBytes(byte[] a, byte[] b, int offset, int count)
        {
            if (a.Length != count) return false;
            for (int i = 0; i < count; i++) if (a[i] != b[offset + i]) return false;
            return true;
        }

        private void WriteLine(Regex regex, int[] index, byte[] bytes, int offset, int count, Stream target, RemapFileResult result)
        {
            if (regex == null) { target.Write(bytes, offset, count); return; }

            string text;
            try { text = Strict.GetString(bytes, offset, count); }
            catch (DecoderFallbackException)
            {
                // Not UTF-8: a script saved in a Windows code page, or a stray
                // binary line. Read in this machine's code page when that gives
                // back exactly these bytes — then every path it can spell is
                // rewritten, Turkish letters included. Otherwise in Latin-1,
                // which maps every byte to one character and back, so a path in
                // plain ASCII can be rewritten with every other byte left as it
                // was. A path the encoding cannot spell stays as it is, and the
                // line is counted rather than silently passed over.
                string view = null;
                Encoding encoding = null;
                bool[] allowed = null;
                if (Ansi != null)
                {
                    try
                    {
                        string decoded = Ansi.GetString(bytes, offset, count);
                        if (SameBytes(Ansi.GetBytes(decoded), bytes, offset, count))
                        {
                            view = decoded; encoding = Ansi; allowed = _ansi;
                        }
                    }
                    catch { }
                }
                if (view == null)
                {
                    view = Latin1.GetString(bytes, offset, count); encoding = Latin1; allowed = _ascii;
                }

                string rewritten = Apply(regex, index, allowed, view);
                if (_heldBack) result.LinesLeftStale++;
                if (!string.Equals(rewritten, view, StringComparison.Ordinal))
                {
                    byte[] raw = encoding.GetBytes(rewritten);
                    target.Write(raw, 0, raw.Length);
                    result.LinesChanged++;
                    return;
                }
                target.Write(bytes, offset, count);
                result.LinesKeptAsBytes++;
                return;
            }

            string replaced = Apply(regex, index, null, text);
            if ((object)replaced == (object)text || string.Equals(replaced, text, StringComparison.Ordinal))
            {
                target.Write(bytes, offset, count);
                return;
            }
            byte[] encoded = Plain.GetBytes(replaced);
            target.Write(encoded, 0, encoded.Length);
            result.LinesChanged++;
        }
    }
}
'@
}

# Rewritten when found: text by name. A compiled Python file, for one, embeds
# its source path with a length prefix, and editing it in place would leave
# Python unable to load it, so known binary types are never touched. Anything
# else — a hook script with no extension, Claude Code's own '.claude.json.backup.<time>'
# copies, a superseded transcript — is read to find out: no NUL byte in its
# first 8 KB means text.
$script:ClaudExtTextExtensions = @(
    '.json', '.jsonl', '.jsonc', '.json5', '.md', '.markdown', '.mdx', '.txt', '.log', '.yaml', '.yml',
    '.toml', '.ini', '.cfg', '.conf', '.env', '.xml', '.html', '.htm', '.css', '.csv', '.ps1', '.psm1',
    '.psd1', '.sh', '.bash', '.zsh', '.fish', '.bat', '.cmd', '.py', '.pyw', '.js', '.mjs', '.cjs', '.ts',
    '.tsx', '.jsx', '.lua', '.rb', '.go', '.rs', '.java', '.cs', '.sql', '.ahk'
)
$script:ClaudExtBinaryExtensions = @(
    '.pyc', '.pyo', '.exe', '.dll', '.so', '.dylib', '.bin', '.dat', '.db', '.sqlite', '.zip', '.gz', '.7z',
    '.tar', '.rar', '.png', '.jpg', '.jpeg', '.gif', '.webp', '.ico', '.bmp', '.pdf', '.doc', '.docx',
    '.xls', '.xlsx', '.ppt', '.pptx', '.woff', '.woff2', '.ttf', '.otf', '.mp3', '.mp4', '.wav', '.class', '.jar'
)

function Test-ClaudExtTextFile {
    <#
    .SYNOPSIS
        True when a file is text that may carry paths worth rewriting.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)

    $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($script:ClaudExtTextExtensions -contains $extension) { return $true }
    if ($script:ClaudExtBinaryExtensions -contains $extension) { return $false }
    if (-not [System.IO.File]::Exists($Path)) { return $false }

    $buffer = [byte[]]::new(8192)
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try { $read = $stream.Read($buffer, 0, $buffer.Length) } finally { $stream.Dispose() }
    }
    catch { return $false }
    return ([array]::IndexOf($buffer, [byte]0, 0, $read) -lt 0)
}

function Get-ClaudExtRemapMode {
    <#
    .SYNOPSIS
        How a file's paths are rewritten: 'json', 'text', 'utf16', or 'copy'
        for a file that is left byte for byte.
    .DESCRIPTION
        UTF-16 first, whatever the extension: Windows PowerShell 5.1 saves a
        script that way, and read as bytes its paths never match. JSON and
        JSON Lines next: there a path appears only escaped, and a raw form
        would take 'D:' before an escape like '\n' for a drive root.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    if ([System.IO.File]::Exists($Path)) {
        $head = [byte[]]::new(2)
        try {
            $stream = [System.IO.File]::OpenRead($Path)
            try { $read = $stream.Read($head, 0, 2) } finally { $stream.Dispose() }
            if ($read -eq 2 -and (($head[0] -eq 0xFF -and $head[1] -eq 0xFE) -or ($head[0] -eq 0xFE -and $head[1] -eq 0xFF))) {
                return 'utf16'
            }
        }
        catch { return 'copy' }
    }

    # By name, not only by the last extension: Claude Code's own copies are
    # '.claude.json.backup.<time>', and hand-made ones 'settings.json.bak'.
    if ([System.IO.Path]::GetFileName($Path) -match '(?i)\.json(l|c|5)?(\.|$)') { return 'json' }
    if (Test-ClaudExtTextFile -Path $Path) { return 'text' }
    return 'copy'
}

function Invoke-ClaudExtUtf16Remap {
    <#
    .SYNOPSIS
        Rewrites a UTF-16 text file, byte order mark and all, and returns how
        many lines changed.
    .DESCRIPTION
        Such files are scripts, small enough to read whole. The output keeps
        the input's byte order and modification time.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [Parameter(Mandatory)][string]$InputPath,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)]$Remapper
    )

    $bytes = [System.IO.File]::ReadAllBytes($InputPath)
    $encoding = if ($bytes[0] -eq 0xFF) { [System.Text.UnicodeEncoding]::new($false, $true) }
                else { [System.Text.UnicodeEncoding]::new($true, $true) }
    $text = $encoding.GetString($bytes, 2, $bytes.Length - 2)
    # A UTF-16 JSON file — what Windows PowerShell 5.1 writes by default — is
    # still JSON, with its paths escaped.
    $json = [System.IO.Path]::GetFileName($InputPath) -match '(?i)\.json(l|c|5)?(\.|$)'
    $rewritten = $Remapper.RemapString($text, $json)
    if ($rewritten -ceq $text) {
        [System.IO.File]::Copy($InputPath, $OutputPath, $true)
        $changed = 0
    }
    else {
        $body = $encoding.GetBytes($rewritten)
        $out = [byte[]]::new(2 + $body.Length)
        $out[0] = $bytes[0]; $out[1] = $bytes[1]
        [System.Array]::Copy($body, 0, $out, 2, $body.Length)
        [System.IO.File]::WriteAllBytes($OutputPath, $out)
        $before = $text -split "`n"; $after = $rewritten -split "`n"
        $changed = 0
        for ($i = 0; $i -lt [math]::Min($before.Count, $after.Count); $i++) { if ($before[$i] -cne $after[$i]) { $changed++ } }
    }
    [System.IO.File]::SetLastWriteTimeUtc($OutputPath, [System.IO.File]::GetLastWriteTimeUtc($InputPath))
    return [long]$changed
}

function New-PathRemapper {
    <#
    .SYNOPSIS
        Compiles a mapping into a remapper that can be reused across files.
    .DESCRIPTION
        Building the matcher is the expensive part, so a restore builds it once
        and hands it to every file.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Mapping)

    $froms = [string[]]@($Mapping.Keys | ForEach-Object { [string]$_ })
    $tos = [string[]]@($froms | ForEach-Object { [string]$Mapping[$_] })
    return [ClaudExt.PathRemapper]::new($froms, $tos)
}

function ConvertTo-RemappedText {
    <#
    .SYNOPSIS
        Rewrites every mapped path inside a block of text.
    .DESCRIPTION
        Paths appear in three forms across Claude's files:
          raw            C:\Users\old\Desktop
          JSON-escaped   C:\\Users\\old\\Desktop     (inside .jsonl records)
          forward-slash  C:/Users/old/Desktop        (some claude.json values)
        All three are rewritten, in a single pass, longest mapping first, and
        only where the old path ends on a boundary — 'C:\Users\ada' does not
        rewrite 'C:\Users\adam'. Windows paths match regardless of case.

        Other spellings are left alone on purpose: Git Bash ('/c/Users/old'),
        WSL ('/mnt/c/...') and URL-encoded links appear only in terminal output
        and command text, which are history rather than paths anything reads
        back.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [System.Collections.IDictionary]$Mapping,
        $Remapper
    )

    if (-not $Remapper) {
        if (-not $Mapping -or $Mapping.Count -eq 0) { return $Text }
        $Remapper = New-PathRemapper -Mapping $Mapping
    }
    return $Remapper.RemapString($Text)
}

function New-PathMapping {
    <#
    .SYNOPSIS
        Builds the old-path to new-path table for a restore.
    .DESCRIPTION
        Paths under the source home are rewritten to the target home
        automatically. Paths elsewhere cannot be inferred and are returned with
        Resolved=$false so a person supplies a new place or keeps the old one.

        'Under' means on a separator boundary: with the home C:\Users\ada, the
        folder C:\Users\adam is somebody else's and is not moved.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceHome,
        [Parameter(Mandatory)][string]$TargetHome,
        [string[]]$ProjectPaths = @()
    )

    if ($SourceHome -eq $TargetHome) { return @() }

    $homeMap = @{ $SourceHome = $TargetHome }
    $entries = foreach ($p in $ProjectPaths) {
        if (-not $p) { continue }
        $to = ConvertTo-MappedPath -Path $p -Mapping $homeMap
        if ($to) { [pscustomobject]@{ From = $p; To = $to; Resolved = $true } }
        else { [pscustomobject]@{ From = $p; To = ''; Resolved = $false } }
    }

    # The home mapping itself always applies — settings files and per-project
    # memory reference it outside any project path. It is shorter than every
    # project path, so a more specific entry wins wherever both match. A
    # session started in the home itself already put it in the list.
    $homeKey = (Get-ClaudExtTrimmedPath $SourceHome).Replace('\', '/')
    $comparison = if (Test-ClaudExtWindowsStylePath $SourceHome) { [System.StringComparison]::OrdinalIgnoreCase }
                  else { [System.StringComparison]::Ordinal }
    $listed = @($entries | Where-Object { (Get-ClaudExtTrimmedPath $_.From).Replace('\', '/').Equals($homeKey, $comparison) })
    if ($listed.Count -gt 0) { return @($entries) }
    @($entries) + @([pscustomobject]@{
        From = $SourceHome; To = $TargetHome; Resolved = $true
    })
}

function Invoke-FileRemap {
    <#
    .SYNOPSIS
        Rewrites a file, applying the path mapping, and returns how many lines
        changed.
    .DESCRIPTION
        Streams the file, so a transcript of any size is never held whole in
        memory. Line endings, untouched lines and lines that are not UTF-8 come
        through byte for byte, and the output keeps the input's modification
        time. Pass -Remapper to reuse one matcher across many files.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [Parameter(Mandatory)][string]$InputPath,
        [Parameter(Mandatory)][string]$OutputPath,
        [System.Collections.IDictionary]$Mapping,
        $Remapper
    )

    if (-not $Remapper) { $Remapper = New-PathRemapper -Mapping $(if ($Mapping) { $Mapping } else { @{} }) }

    $InputPath = Resolve-ClaudExtFullPath $InputPath
    $OutputPath = Resolve-ClaudExtFullPath $OutputPath
    $outDir = Split-Path -Parent $OutputPath
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }

    # The same choice a restore makes, so what this rewrites is what a
    # restore would write.
    switch (Get-ClaudExtRemapMode -Path $InputPath) {
        'utf16' { return Invoke-ClaudExtUtf16Remap -InputPath $InputPath -OutputPath $OutputPath -Remapper $Remapper }
        'json'  { return $Remapper.RemapFile($InputPath, $OutputPath, $true).LinesChanged }
        default { return $Remapper.RemapFile($InputPath, $OutputPath, $false).LinesChanged }
    }
}

function ConvertTo-RemappedJsonValue {
    <#
    .SYNOPSIS
        Rewrites paths inside a parsed JSON value: every string, and every key.
    .DESCRIPTION
        Keys matter as much as values — ~/.claude.json files each project's
        trust and tool decisions under the project's path. Two keys can become
        one after the rewrite ('C:\Users\old\x' and 'c:\users\old\x' on a
        Windows machine); their entries are then merged, the first one's values
        winning where both have the same field.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory)]$Remapper
    )

    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return $Remapper.RemapString($Value) }

    if ($Value -is [System.Collections.IDictionary]) {
        $out = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
        foreach ($key in @($Value.Keys)) {
            $newKey = $Remapper.RemapString([string]$key)
            $newValue = ConvertTo-RemappedJsonValue -Value $Value[$key] -Remapper $Remapper
            if (-not $out.Contains($newKey)) { $out[$newKey] = $newValue; continue }
            $existing = $out[$newKey]
            if ($existing -is [System.Collections.IDictionary] -and $newValue -is [System.Collections.IDictionary]) {
                foreach ($k in @($newValue.Keys)) { if (-not $existing.Contains($k)) { $existing[$k] = $newValue[$k] } }
            }
        }
        return $out
    }

    if ($Value -is [System.Collections.IList]) {
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $Value) { $list.Add((ConvertTo-RemappedJsonValue -Value $item -Remapper $Remapper)) }
        return , $list.ToArray()
    }

    return $Value
}
