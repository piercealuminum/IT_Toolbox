function New-ITPassphrase {
    <#
    .SYNOPSIS
    Generates easy-to-read temporary passwords like Maple-Rocket-Tidy-Lemon47 for password resets.

    .DESCRIPTION
    Picks random words from a built-in list of short, common words using a cryptographic
    random number generator, capitalizes them, joins them with a separator and adds digits.
    The result has upper case, lower case, a digit and a symbol, so it meets the Active
    Directory and Entra ID complexity rules, and it is easy to read out over the phone.

    With the defaults (4 words from the 551-word list plus 2 digits) each passphrase has
    about 43 bits of entropy: fine for a temporary password the user must change at next
    sign-in, not meant for service accounts or anything long-lived.

    Defaults come from the Passphrase settings; see Get-ITToolkitSetting.

    .PARAMETER WordCount
    Number of words, 2 to 10.

    .PARAMETER Separator
    Text between words. Use '' for none.

    .PARAMETER Digits
    Number of digits added at the end, 0 to 6.

    .PARAMETER Count
    How many passphrases to generate.

    .PARAMETER AsSecureString
    Returns SecureString objects, for example to pass to Set-ADAccountPassword.

    .EXAMPLE
    New-ITPassphrase

    .EXAMPLE
    New-ITPassphrase -Count 5 -WordCount 3

    .EXAMPLE
    Set-ADAccountPassword jsmith -Reset -NewPassword (New-ITPassphrase -AsSecureString)

    Resets a password without the passphrase appearing on screen.

    .OUTPUTS
    System.String, or System.Security.SecureString with -AsSecureString.
    #>
    [CmdletBinding()]
    [OutputType([string], [securestring])]
    param(
        [ValidateRange(2, 10)]
        [int]$WordCount,

        [AllowEmptyString()]
        [string]$Separator,

        [ValidateRange(0, 6)]
        [int]$Digits,

        [ValidateRange(1, 1000)]
        [int]$Count = 1,

        [switch]$AsSecureString
    )

    $settings = (Get-ITSettings).Passphrase
    if (-not $PSBoundParameters.ContainsKey('WordCount')) { $WordCount = $settings.WordCount }
    if (-not $PSBoundParameters.ContainsKey('Separator')) { $Separator = $settings.Separator }
    if (-not $PSBoundParameters.ContainsKey('Digits')) { $Digits = $settings.Digits }

    $words = Get-ITWordList
    if ($words.Count -lt 100) { throw "ITToolkit: the word list has only $($words.Count) words; it needs at least 100." }
    $bits = $WordCount * [math]::Log($words.Count, 2) + $Digits * [math]::Log(10, 2)
    Write-Verbose ('Each passphrase has about {0:N0} bits of entropy ({1} words from {2}, {3} digits).' -f $bits, $WordCount, $words.Count, $Digits)

    for ($n = 0; $n -lt $Count; $n++) {
        $picked = for ($i = 0; $i -lt $WordCount; $i++) {
            $word = $words[(Get-ITRandomIndex -Maximum $words.Count)]
            $word.Substring(0, 1).ToUpperInvariant() + $word.Substring(1)
        }
        $number = -join @(for ($i = 0; $i -lt $Digits; $i++) { Get-ITRandomIndex -Maximum 10 })
        $phrase = (@($picked) -join $Separator) + $number

        if ($AsSecureString) {
            $secure = New-Object System.Security.SecureString
            foreach ($character in $phrase.ToCharArray()) { $secure.AppendChar($character) }
            $secure.MakeReadOnly()
            $secure
        }
        else {
            $phrase
        }
    }
}
