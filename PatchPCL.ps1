[CmdletBinding()]
param(
    [string]$InputExe = '',
    [string]$SourceZip = '',
    [string]$OutputExe = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrEmpty($OutputExe)) { $OutputExe = Join-Path $scriptDir 'out\Plain Craft Launcher 2.exe' }
$cecilPath = @(
    (Join-Path $scriptDir 'lib\Mono.Cecil.dll'),
    (Join-Path (Split-Path $scriptDir -Parent) 'PCL-main\pcl-patch\lib\Mono.Cecil.dll'),
    (Join-Path (Split-Path $scriptDir -Parent) 'pcl-patch\lib\Mono.Cecil.dll')
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $cecilPath) { throw "缺少 lib\Mono.Cecil.dll。请把补丁包中的 lib 文件夹一起复制到 $scriptDir\lib（只复制 PatchPCL.ps1 无法运行）。" }
if (-not ('Mono.Cecil.AssemblyDefinition' -as [type])) {
    Add-Type -Path $cecilPath
}
Add-Type -AssemblyName System.Resources.ResourceManager | Out-Null

$restrictMessage = '为遵守相关法律法规，PCL 暂时不再提供 MC 下载功能，非常抱歉 qwq……'
$tempRoot = Join-Path $env:TEMP ('pcl-unlock-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null

function New-I {
    param([Mono.Cecil.Cil.OpCode]$Code, $Operand)
    if ($null -eq $Operand) {
        return [Mono.Cecil.Cil.Instruction]::Create($Code)
    }
    return [Mono.Cecil.Cil.Instruction]::Create($Code, $Operand)
}

function Get-TypeDef($Asm, [string]$FullName) {
    $t = $Asm.MainModule.GetType($FullName)
    if ($null -eq $t) { throw "找不到类型：$FullName" }
    return $t
}

function Get-MethodDef($Type, [string]$Name, [int]$ParamCount) {
    $ms = @($Type.Methods | Where-Object { $_.Name -eq $Name -and $_.Parameters.Count -eq $ParamCount })
    if ($ms.Count -ne 1) {
        throw "方法匹配失败：$($Type.FullName)::$Name/$ParamCount，匹配数=$($ms.Count)"
    }
    return $ms[0]
}

function Find-MemberRef($Asm, [string]$Name, [string]$DeclaringTypeFullName, [int]$ParamCount = -1) {
    $refs = @($Asm.MainModule.GetMemberReferences() | Where-Object {
        $_.Name -eq $Name -and
        $_.DeclaringType -ne $null -and
        $_.DeclaringType.FullName -eq $DeclaringTypeFullName -and
        ($ParamCount -lt 0 -or $_.Parameters.Count -eq $ParamCount)
    })
    if ($refs.Count -eq 0) { throw "找不到成员引用：$DeclaringTypeFullName::$Name/$ParamCount" }
    return $refs[0]
}

function Export-EmbeddedDeps($Asm, [string]$DepsDir) {
    New-Item -ItemType Directory -Path $DepsDir -Force | Out-Null
    $res = $Asm.MainModule.Resources | Where-Object { $_.Name -eq 'PCL.Resources.resources' }
    if ($null -eq $res) { throw '找不到 PCL.Resources.resources' }
    $ms = New-Object System.IO.MemoryStream(,$res.GetResourceData())
    $reader = New-Object System.Resources.ResourceReader($ms)
    try {
        $e = $reader.GetEnumerator()
        while ($e.MoveNext()) {
            if ($e.Value -is [byte[]]) {
                $name = [string]$e.Key
                if (-not $name.EndsWith('.dll', [StringComparison]::OrdinalIgnoreCase)) { $name = $name + '.dll' }
                [System.IO.File]::WriteAllBytes((Join-Path $DepsDir $name), $e.Value)
            }
        }
    } finally {
        $reader.Close()
    }
}

function New-Resolver([string]$DepsDir) {
    $resolver = New-Object Mono.Cecil.DefaultAssemblyResolver
    $resolver.AddSearchDirectory($DepsDir)
    $rt = [System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()
    $resolver.AddSearchDirectory($rt)
    $wpf = Join-Path $rt 'WPF'
    if (Test-Path $wpf) { $resolver.AddSearchDirectory($wpf) }
    return $resolver
}

function Read-AssemblyWithResolver([string]$Path, $Resolver) {
    $rp = New-Object Mono.Cecil.ReaderParameters
    $rp.AssemblyResolver = $Resolver
    return [Mono.Cecil.AssemblyDefinition]::ReadAssembly($Path, $rp)
}

# ---------- 1. 下载页“原版游戏”：把被常量折叠掉的假 LoaderTask 换回 DlClientListLoader ----------
function Patch-LoaderInit($Asm) {
    $t = Get-TypeDef $Asm 'PCL.PageDownloadInstall'
    $m = Get-MethodDef $t 'LoaderInit' 0
    $ins = $m.Body.Instructions

    $start = -1
    for ($i = 0; $i -lt $ins.Count; $i++) {
        if ($ins[$i].OpCode -eq [Mono.Cecil.Cil.OpCodes]::Ldstr -and $ins[$i].Operand -eq '关闭下载') { $start = $i; break }
    }
    if ($start -lt 0) { throw 'LoaderInit：找不到“关闭下载”字符串' }

    $end = -1
    for ($i = $start; $i -lt $ins.Count; $i++) {
        $op = $ins[$i].Operand
        if ($ins[$i].OpCode -eq [Mono.Cecil.Cil.OpCodes]::Newobj -and
            $op -is [Mono.Cecil.MethodReference] -and
            $op.DeclaringType -ne $null -and
            $op.DeclaringType.Name -eq 'LoaderTask`2') { $end = $i; break }
    }
    if ($end -lt 0) { throw 'LoaderInit：找不到假 LoaderTask 构造' }

    for ($i = $end; $i -ge $start; $i--) { $ins.RemoveAt($i) }

    $modDownload = Get-TypeDef $Asm 'PCL.ModDownload'
    $field = @($modDownload.Fields | Where-Object { $_.Name -eq 'DlClientListLoader' })
    if ($field.Count -ne 1) { throw '找不到 DlClientListLoader 字段' }
    $ins.Insert($start, (New-I ([Mono.Cecil.Cil.OpCodes]::Ldsfld) $field[0]))
    $m.Body.MaxStackSize = [Math]::Max([int]$m.Body.MaxStackSize, 10)
    Write-Host '  [OK] PageDownloadInstall.LoaderInit -> DlClientListLoader'
}

# ---------- 2. 版本修改页：基础版本卡片改为可见 ----------
function Patch-LoadInstanceFinished($Asm) {
    $t = Get-TypeDef $Asm 'PCL.PageDownloadModify'
    $m = Get-MethodDef $t 'LoadInstanceFinished' 1
    $ins = $m.Body.Instructions
    $found = $false
    for ($i = 1; $i -lt ($ins.Count - 1); $i++) {
        if ($ins[$i].OpCode -ne [Mono.Cecil.Cil.OpCodes]::Ldc_I4_2) { continue }
        $prev = $ins[$i - 1].Operand
        $next = $ins[$i + 1].Operand
        if ($prev -is [Mono.Cecil.MethodReference] -and $prev.Name -eq 'get_CardMinecraft' -and
            $next -is [Mono.Cecil.MethodReference] -and $next.Name -eq 'set_Visibility') {
            $ins[$i].OpCode = [Mono.Cecil.Cil.OpCodes]::Ldc_I4_0
            $found = $true
            break
        }
    }
    if (-not $found) { throw 'LoadInstanceFinished：找不到 CardMinecraft 的 Visibility 设置' }
    Write-Host '  [OK] PageDownloadModify.LoadInstanceFinished -> CardMinecraft 可见'
}

# ---------- 3. 资源详情：整合包版本条目恢复“安装”回调 ----------
function Patch-ResourceDetail($Asm) {
    $t = Get-TypeDef $Asm 'PCL.PageDownloadResourceDetail'
    $m = Get-MethodDef $t 'InitializeStackResourceVersions' 1
    $ins = $m.Body.Instructions

    $k = -1
    for ($i = 0; $i -lt $ins.Count; $i++) {
        $op = $ins[$i].Operand
        if ($ins[$i].OpCode -eq [Mono.Cecil.Cil.OpCodes]::Ldftn -and
            $op -is [Mono.Cecil.MethodReference] -and $op.Name -eq 'Save_Click') { $k = $i; break }
    }
    if ($k -lt 0) { throw 'InitializeStackResourceVersions：找不到 Save_Click 的 ldftn' }

    $ctorRef = $ins[$k + 1].Operand
    if (-not ($ctorRef -is [Mono.Cecil.MethodReference])) { throw 'InitializeStackResourceVersions：找不到 ClickEventHandler 构造' }
    if ($ins[$k + 2].OpCode -ne [Mono.Cecil.Cil.OpCodes]::Ldnull) { throw 'InitializeStackResourceVersions：预期 ldnull 位置不符' }

    $targetField = @($t.Fields | Where-Object { $_.Name -eq 'TargetResourceType' })
    if ($targetField.Count -ne 1) { throw 'InitializeStackResourceVersions：找不到 TargetResourceType 字段' }

    $installDef = Get-MethodDef $t 'Install_Click' 2
    $saveDef = Get-MethodDef $t 'Save_Click' 2

    # 删除原有的两个 handler 构造（ldarg.0, ldftn Save_Click, newobj, ldnull）
    for ($i = 0; $i -lt 4; $i++) { $ins.RemoveAt($k - 1) }

    # 恢复原条件：仅当 TargetResourceType = ModPack(2) 时才挂安装回调，其余资源仍只挂保存回调
    $saveOnlyLabel = New-I ([Mono.Cecil.Cil.OpCodes]::Ldnull)
    $afterLabel = New-I ([Mono.Cecil.Cil.OpCodes]::Ldarg_0)
    $block = @(
        (New-I ([Mono.Cecil.Cil.OpCodes]::Ldarg_0)),
        (New-I ([Mono.Cecil.Cil.OpCodes]::Ldfld) $targetField[0]),
        (New-I ([Mono.Cecil.Cil.OpCodes]::Ldc_I4_2)),
        (New-I ([Mono.Cecil.Cil.OpCodes]::Bne_Un) $saveOnlyLabel),
        (New-I ([Mono.Cecil.Cil.OpCodes]::Ldarg_0)),
        (New-I ([Mono.Cecil.Cil.OpCodes]::Ldftn) $installDef),
        (New-I ([Mono.Cecil.Cil.OpCodes]::Newobj) $ctorRef),
        (New-I ([Mono.Cecil.Cil.OpCodes]::Br) $afterLabel),
        $saveOnlyLabel,
        $afterLabel,
        (New-I ([Mono.Cecil.Cil.OpCodes]::Ldftn) $saveDef),
        (New-I ([Mono.Cecil.Cil.OpCodes]::Newobj) $ctorRef)
    )
    $insertAt = $k - 1
    foreach ($x in $block) { $ins.Insert($insertAt, $x); $insertAt++ }
    $m.Body.MaxStackSize = [Math]::Max([int]$m.Body.MaxStackSize, 8)
    Write-Host '  [OK] PageDownloadResourceDetail.InitializeStackResourceVersions -> ModPack 恢复 Install+Save，其余资源保持 Save'
}

# ---------- 4. ModpackInstall(File, InstanceName, Logo)：恢复安装分发 ----------
function Patch-ModpackInstallFile($Asm) {
    $t = Get-TypeDef $Asm 'PCL.ModModpack'
    $m = Get-MethodDef $t 'ModpackInstall' 3
    $ins = $m.Body.Instructions
    $vars = $m.Body.Variables

    $anchor = -1
    for ($i = 0; $i -lt $ins.Count; $i++) {
        if ($ins[$i].OpCode -eq [Mono.Cecil.Cil.OpCodes]::Ldstr -and $ins[$i].Operand -eq $restrictMessage) { $anchor = $i; break }
    }
    if ($anchor -lt 0) { throw 'ModpackInstall(3)：找不到限制提示字符串' }
    if ($ins[$anchor + 1].OpCode -ne [Mono.Cecil.Cil.OpCodes]::Newobj -or
        $ins[$anchor + 2].OpCode -ne [Mono.Cecil.Cil.OpCodes]::Throw) {
        throw 'ModpackInstall(3)：限制代码结构不符'
    }

    $removed1 = $ins[$anchor + 1]
    $removed2 = $ins[$anchor + 2]
    $ins.RemoveAt($anchor + 1)
    $ins.RemoveAt($anchor + 1)

    # 检查是否有分支指向被删除的指令
    foreach ($x in $ins) {
        if ($x.Operand -is [Mono.Cecil.Cil.Instruction] -and ($x.Operand -eq $removed1 -or $x.Operand -eq $removed2)) {
            throw 'ModpackInstall(3)：存在指向被删除指令的分支'
        }
    }

    # 锚点改为 ldloc PackType，后接 switch
    $anchorIns = $ins[$anchor]
    $anchorIns.OpCode = [Mono.Cecil.Cil.OpCodes]::Ldloc
    $anchorIns.Operand = $vars[4]

    $lret = New-I ([Mono.Cecil.Cil.OpCodes]::Ldloc) $vars[0]
    $ret = New-I ([Mono.Cecil.Cil.OpCodes]::Ret)

    $curse = Get-MethodDef $t 'InstallPackCurseForge' 5
    $modrinth = Get-MethodDef $t 'InstallPackModrinth' 5
    $hmcl = Get-MethodDef $t 'InstallPackHMCL' 3
    $mmc = Get-MethodDef $t 'InstallPackMMC' 3
    $mcbbs = Get-MethodDef $t 'InstallPackMCBBS' 4
    $launcher = Get-MethodDef $t 'InstallPackLauncherPack' 3
    $compress = Get-MethodDef $t 'InstallPackCompress' 2

    function New-CaseBlock($Target, [string[]]$Plan, $Vars, $Lret) {
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($p in $Plan) {
            switch ($p) {
                'file' { $list.Add((New-I ([Mono.Cecil.Cil.OpCodes]::Ldarg_0))) }
                'archive' { $list.Add((New-I ([Mono.Cecil.Cil.OpCodes]::Ldloc) $Vars[1])) }
                'base' { $list.Add((New-I ([Mono.Cecil.Cil.OpCodes]::Ldloc) $Vars[2])) }
                'instance' { $list.Add((New-I ([Mono.Cecil.Cil.OpCodes]::Ldarg_1))) }
                'logo' { $list.Add((New-I ([Mono.Cecil.Cil.OpCodes]::Ldarg_2))) }
                default { throw "未知参数计划：$p" }
            }
        }
        $list.Add((New-I ([Mono.Cecil.Cil.OpCodes]::Call) $Target))
        $list.Add((New-I ([Mono.Cecil.Cil.OpCodes]::Stloc) $Vars[0]))
        $list.Add((New-I ([Mono.Cecil.Cil.OpCodes]::Leave) $Lret))
        return ,$list.ToArray()
    }

    $compressBlock = New-CaseBlock $compress @('file', 'archive') $vars $lret
    $c0 = New-CaseBlock $curse @('file', 'archive', 'base', 'instance', 'logo') $vars $lret
    $c1 = New-CaseBlock $hmcl @('file', 'archive', 'base') $vars $lret
    $c2 = New-CaseBlock $mmc @('file', 'archive', 'base') $vars $lret
    $c3 = New-CaseBlock $mcbbs @('file', 'archive', 'base', 'instance') $vars $lret
    $c4 = New-CaseBlock $modrinth @('file', 'archive', 'base', 'instance', 'logo') $vars $lret
    $c9 = New-CaseBlock $launcher @('file', 'archive', 'base') $vars $lret

    $targets = [Mono.Cecil.Cil.Instruction[]]@(
        $c0[0], $c1[0], $c2[0], $c3[0], $c4[0],
        $compressBlock[0], $compressBlock[0], $compressBlock[0], $compressBlock[0], $c9[0]
    )
    $switch = New-I ([Mono.Cecil.Cil.OpCodes]::Switch) $targets

    $insertAt = $anchor + 1
    $blocks = @($switch) + @($compressBlock) + @($c0) + @($c1) + @($c2) + @($c3) + @($c4) + @($c9)
    foreach ($x in $blocks) {
        $ins.Insert($insertAt, $x)
        $insertAt++
    }

    $ins.Add($lret)
    $ins.Add($ret)

    $fin = @($m.Body.ExceptionHandlers | Where-Object {
        $_.HandlerType -eq [Mono.Cecil.Cil.ExceptionHandlerType]::Finally -and $null -eq $_.HandlerEnd
    })
    if ($fin.Count -ne 1) { throw 'ModpackInstall(3)：找不到外层 finally 处理器' }
    $fin[0].HandlerEnd = $lret
    $m.Body.MaxStackSize = [Math]::Max([int]$m.Body.MaxStackSize, 8)
    Write-Host '  [OK] ModModpack.ModpackInstall(File,...) -> 恢复 InstallPack* 分发'
}

# ---------- 5. ModpackInstall()：恢复文件选择 + 后台线程 ----------
function Patch-ModpackInstallDialog($Asm) {
    $t = Get-TypeDef $Asm 'PCL.ModModpack'
    $m = Get-MethodDef $t 'ModpackInstall' 0
    $body = $m.Body
    $body.Instructions.Clear()

    # 从 ModJava.ManuallyImportJava 里复用 SelectFile / FirstOrDefault 引用
    $modJava = Get-TypeDef $Asm 'PCL.ModJava'
    $mj = Get-MethodDef $modJava 'ManuallyImportJava' 0
    $selectFileRef = $null
    $firstOrDefaultRef = $null
    $oneOfImplicitRef = $null
    $nullableCtorRef = $null
    foreach ($x in $mj.Body.Instructions) {
        $op = $x.Operand
        if ($op -is [Mono.Cecil.MethodReference]) {
            if ($op.Name -eq 'SelectFile' -and $op.DeclaringType -ne $null -and $op.DeclaringType.Name -eq 'Dialogs') { $selectFileRef = $op }
            if ($op.Name -eq 'FirstOrDefault' -and $op.DeclaringType -ne $null -and $op.DeclaringType.Name -eq 'Enumerable') { $firstOrDefaultRef = $op }
            if ($op.Name -eq 'op_Implicit' -and $op.DeclaringType -ne $null -and $op.DeclaringType.Name -eq 'OneOf`2') { $oneOfImplicitRef = $op }
            if ($op.Name -eq '.ctor' -and $op.DeclaringType -ne $null -and $op.DeclaringType.Name -eq 'Nullable`1') { $nullableCtorRef = $op }
        }
    }
    if ($null -eq $selectFileRef) { throw '找不到 Dialogs.SelectFile 引用' }
    if ($null -eq $firstOrDefaultRef) { throw '找不到 Enumerable.FirstOrDefault 引用' }
    if ($null -eq $oneOfImplicitRef) { throw '找不到 OneOf.op_Implicit 引用' }
    if ($null -eq $nullableCtorRef) { throw '找不到 Nullable 构造引用' }

    $isNullRef = Find-MemberRef $Asm 'IsNullOrEmpty' 'System.String' 1
    $actionCtor = Find-MemberRef $Asm '.ctor' 'System.Action' 2

    $modBase = Get-TypeDef $Asm 'PCL.ModBase'
    $runInThread = @($modBase.Methods | Where-Object { $_.Name -eq 'RunInThread' -and $_.Parameters.Count -eq 1 })
    if ($runInThread.Count -ne 1) { throw '找不到 RunInThread(Action)' }

    $closure = @($t.NestedTypes | Where-Object { $_.Name -eq '_Closure$__0-0' })
    if ($closure.Count -ne 1) { throw '找不到 _Closure$__0-0' }
    $closureType = $closure[0]
    $closureCtor = Get-MethodDef $closureType '.ctor' 0
    $closureLambda = Get-MethodDef $closureType '_Lambda$__0' 0
    $closureField = @($closureType.Fields | Where-Object { $_.Name -eq '$VB$Local_File' })
    if ($closureField.Count -ne 1) { throw '找不到 $VB$Local_File 字段' }

    $stringType = $Asm.MainModule.TypeSystem.String
    $varFile = New-Object Mono.Cecil.Cil.VariableDefinition($stringType)
    $body.Variables.Add($varFile) | Out-Null

    $lret = New-I ([Mono.Cecil.Cil.OpCodes]::Ret)
    $list = New-Object System.Collections.Generic.List[object]
    $list.Add((New-I ([Mono.Cecil.Cil.OpCodes]::Ldstr) '选择整合包压缩文件'))
    $list.Add((New-I ([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0)))
    $list.Add((New-I ([Mono.Cecil.Cil.OpCodes]::Ldnull)))
    $list.Add((New-I ([Mono.Cecil.Cil.OpCodes]::Ldstr) '整合包文件|*.rar;*.zip;*.mrpack'))
    $list.Add((New-I ([Mono.Cecil.Cil.OpCodes]::Call) $oneOfImplicitRef))
    $list.Add((New-I ([Mono.Cecil.Cil.OpCodes]::Newobj) $nullableCtorRef))
    $list.Add((New-I ([Mono.Cecil.Cil.OpCodes]::Call) $selectFileRef))
    $list.Add((New-I ([Mono.Cecil.Cil.OpCodes]::Call) $firstOrDefaultRef))
    $list.Add((New-I ([Mono.Cecil.Cil.OpCodes]::Stloc) $varFile))
    $list.Add((New-I ([Mono.Cecil.Cil.OpCodes]::Ldloc) $varFile))
    $list.Add((New-I ([Mono.Cecil.Cil.OpCodes]::Call) $isNullRef))
    $list.Add((New-I ([Mono.Cecil.Cil.OpCodes]::Brtrue) $lret))
    $list.Add((New-I ([Mono.Cecil.Cil.OpCodes]::Newobj) $closureCtor))
    $list.Add((New-I ([Mono.Cecil.Cil.OpCodes]::Dup)))
    $list.Add((New-I ([Mono.Cecil.Cil.OpCodes]::Ldloc) $varFile))
    $list.Add((New-I ([Mono.Cecil.Cil.OpCodes]::Stfld) $closureField[0]))
    $list.Add((New-I ([Mono.Cecil.Cil.OpCodes]::Ldftn) $closureLambda))
    $list.Add((New-I ([Mono.Cecil.Cil.OpCodes]::Newobj) $actionCtor))
    $list.Add((New-I ([Mono.Cecil.Cil.OpCodes]::Call) $runInThread[0]))
    $list.Add((New-I ([Mono.Cecil.Cil.OpCodes]::Ret)))
    $list.Add($lret)

    foreach ($x in $list) { $body.Instructions.Add($x) }
    $body.InitLocals = $true
    $body.MaxStackSize = 8
    Write-Host '  [OK] ModModpack.ModpackInstall() -> 文件选择 + RunInThread'
}

# ---------- 主流程 ----------
if (-not $InputExe) {
    # 优先使用脚本旁边的官方 exe；否则自动查找发布包
    $localExe = Join-Path $scriptDir 'Plain Craft Launcher 2.exe'
    if (Test-Path $localExe) {
        $InputExe = $localExe
    } else {
        if (-not $SourceZip) {
            $SourceZip = @(
                (Join-Path $scriptDir '最新正式版.zip'),
                (Join-Path (Split-Path $scriptDir -Parent) '最新正式版.zip'),
                (Join-Path (Split-Path $scriptDir -Parent) 'PCL-main\最新正式版.zip'),
                (Join-Path (Get-Location) '最新正式版.zip')
            ) | Where-Object { Test-Path $_ } | Select-Object -First 1
        }
        if (-not $SourceZip -or -not (Test-Path $SourceZip)) {
            throw "找不到发布包或官方 exe。请把官方 Plain Craft Launcher 2.exe 放到 $scriptDir，或用 -InputExe 指定 exe / -SourceZip 指定 zip。"
        }
        $extractDir = Join-Path $tempRoot 'src'
        New-Item -ItemType Directory -Path $extractDir | Out-Null
        Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
        [System.IO.Compression.ZipFile]::ExtractToDirectory($SourceZip, $extractDir)
        $InputExe = @(Get-ChildItem -Path $extractDir -Recurse -Filter '*.exe' | Sort-Object Length -Descending)[0].FullName
    }
}
if (-not (Test-Path $InputExe)) { throw "找不到输入 exe：$InputExe" }
$outputDir = Split-Path $OutputExe -Parent
if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir | Out-Null }
if (Test-Path $OutputExe) { Remove-Item -Force $OutputExe }

Write-Host "输入：$InputExe"
Write-Host "输出：$OutputExe"

$depsDir = Join-Path $tempRoot 'deps'
$probeAsm = [Mono.Cecil.AssemblyDefinition]::ReadAssembly($InputExe)
Export-EmbeddedDeps $probeAsm $depsDir
$probeAsm.Dispose()

$resolver = New-Resolver $depsDir
$asm = Read-AssemblyWithResolver $InputExe $resolver

Write-Host '开始打补丁：'
Patch-LoaderInit $asm
Patch-LoadInstanceFinished $asm
Patch-ResourceDetail $asm
Patch-ModpackInstallFile $asm
Patch-ModpackInstallDialog $asm

$asm.Write($OutputExe)
$asm.Dispose()
Write-Host "已写出：$OutputExe"

# ---------- 验证 ----------
Write-Host '验证补丁：'
$vresolver = New-Resolver $depsDir
$v = Read-AssemblyWithResolver $OutputExe $vresolver
$checkErrors = New-Object System.Collections.Generic.List[string]

function Check($Condition, [string]$Message) {
    if (-not $Condition) { $script:checkErrors.Add($Message) }
}

$li = Get-MethodDef (Get-TypeDef $v 'PCL.PageDownloadInstall') 'LoaderInit' 0
$liText = @($li.Body.Instructions | ForEach-Object { if ($_.Operand -is [Mono.Cecil.FieldReference]) { $_.Operand.Name } else { '' } })
Check -Condition (-not ($li.Body.Instructions | Where-Object { $_.OpCode -eq [Mono.Cecil.Cil.OpCodes]::Ldstr -and $_.Operand -eq '关闭下载' })) -Message 'LoaderInit 仍包含关闭下载'
Check -Condition ($li.Body.Instructions | Where-Object { $_.OpCode -eq [Mono.Cecil.Cil.OpCodes]::Ldsfld -and $_.Operand -is [Mono.Cecil.FieldReference] -and $_.Operand.Name -eq 'DlClientListLoader' }) -Message 'LoaderInit 未引用 DlClientListLoader'

$lif = Get-MethodDef (Get-TypeDef $v 'PCL.PageDownloadModify') 'LoadInstanceFinished' 1
$liIns = $lif.Body.Instructions
$cardOk = $false
for ($i = 1; $i -lt ($liIns.Count - 1); $i++) {
    if ($liIns[$i - 1].Operand -is [Mono.Cecil.MethodReference] -and $liIns[$i - 1].Operand.Name -eq 'get_CardMinecraft' -and
        $liIns[$i].OpCode -eq [Mono.Cecil.Cil.OpCodes]::Ldc_I4_0 -and
        $liIns[$i + 1].Operand -is [Mono.Cecil.MethodReference] -and $liIns[$i + 1].Operand.Name -eq 'set_Visibility') { $cardOk = $true }
}
Check -Condition $cardOk -Message 'CardMinecraft 未设为可见'

$rd = Get-MethodDef (Get-TypeDef $v 'PCL.PageDownloadResourceDetail') 'InitializeStackResourceVersions' 1
Check -Condition ($rd.Body.Instructions | Where-Object { $_.OpCode -eq [Mono.Cecil.Cil.OpCodes]::Ldftn -and $_.Operand -is [Mono.Cecil.MethodReference] -and $_.Operand.Name -eq 'Install_Click' }) -Message '资源详情未恢复 Install_Click'
Check -Condition ($rd.Body.Instructions | Where-Object { $_.OpCode -eq [Mono.Cecil.Cil.OpCodes]::Ldftn -and $_.Operand -is [Mono.Cecil.MethodReference] -and $_.Operand.Name -eq 'Save_Click' }) -Message '资源详情未保留 Save_Click'

$mi3 = Get-MethodDef (Get-TypeDef $v 'PCL.ModModpack') 'ModpackInstall' 3
$mi3Ins = $mi3.Body.Instructions
Check -Condition (-not ($mi3Ins | Where-Object { $_.OpCode -eq [Mono.Cecil.Cil.OpCodes]::Ldstr -and $_.Operand -eq $restrictMessage })) -Message 'ModpackInstall(3) 仍含限制提示'
$installTargets = @('InstallPackCurseForge', 'InstallPackModrinth', 'InstallPackHMCL', 'InstallPackMMC', 'InstallPackMCBBS', 'InstallPackLauncherPack', 'InstallPackCompress')
foreach ($n in $installTargets) {
    Check -Condition ($mi3Ins | Where-Object { $_.OpCode -eq [Mono.Cecil.Cil.OpCodes]::Call -and $_.Operand -is [Mono.Cecil.MethodReference] -and $_.Operand.Name -eq $n }) -Message "ModpackInstall(3) 缺少 $n 调用"
}
Check -Condition ($mi3Ins | Where-Object { $_.OpCode -eq [Mono.Cecil.Cil.OpCodes]::Switch }) -Message 'ModpackInstall(3) 缺少 switch'
$mi0 = Get-MethodDef (Get-TypeDef $v 'PCL.ModModpack') 'ModpackInstall' 0
Check -Condition (-not ($mi0.Body.Instructions | Where-Object { $_.OpCode -eq [Mono.Cecil.Cil.OpCodes]::Ldstr -and $_.Operand -eq $restrictMessage })) -Message 'ModpackInstall(0) 仍含限制提示'
Check -Condition ($mi0.Body.Instructions | Where-Object { $_.OpCode -eq [Mono.Cecil.Cil.OpCodes]::Call -and $_.Operand -is [Mono.Cecil.MethodReference] -and $_.Operand.Name -eq 'SelectFile' }) -Message 'ModpackInstall(0) 缺少 SelectFile'
Check -Condition ($mi0.Body.Instructions | Where-Object { $_.OpCode -eq [Mono.Cecil.Cil.OpCodes]::Call -and $_.Operand -is [Mono.Cecil.MethodReference] -and $_.Operand.Name -eq 'RunInThread' }) -Message 'ModpackInstall(0) 缺少 RunInThread'
Check -Condition ($mi0.Body.Instructions | Where-Object { $_.OpCode -eq [Mono.Cecil.Cil.OpCodes]::Stfld -and $_.Operand -is [Mono.Cecil.FieldReference] -and $_.Operand.Name -eq '$VB$Local_File' }) -Message 'ModpackInstall(0) 缺少闭包字段写入'

$v.Dispose()

if ($checkErrors.Count -gt 0) {
    Write-Host '验证失败：' -ForegroundColor Red
    $checkErrors | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

$hash = (Get-FileHash -Algorithm SHA256 $OutputExe).Hash
Write-Host '全部验证通过。' -ForegroundColor Green
Write-Host "SHA256: $hash"
Write-Host "临时目录：$tempRoot"
