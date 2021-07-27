#!/bin/bash
# Repositry: https://github.com/hirtanak/hpcbmtenv
# Last update: 2021/7/27
SCRIPTVERSION=0.3.2

echo "SCRIPTVERSION: $SCRIPTVERSION - startup azure hpc delopment create script..."

### Terraform ファイルチェック
if [ -s "./*.tfvars" ]; then
	SSHKEYDIR="~/.ssh/id_rsa"
	### 基本設定
	TFVARFILE="./dev.tfvars" # 利用するtfvarsファイル
	MyResourceGroup=$(grep -i VMPREFIX ${TFVARFILE} | cut -d " " -f 3 | sed 's/"//g')
	VMPREFIX=$(grep -i VMPREFIX ${TFVARFILE} | cut -d " " -f 3 | sed 's/"//g')
	MAXVM=$(grep -i compute-count ${TFVARFILE} | cut -d " " -f 3 | sed 's/"//g')
	# 利用するSSH鍵が ./${VMPREFIX} を想定しているため
	# cp ~/.ssh/id_rsa ./${VMPREFIX}
	echo $MAXVM
else
	### 基本設定
	MyResourceGroup=tmcbmt01
	VMPREFIX=tmcbmt01
	MAXVM=8 # 作成するコンピュートノード数
	# SSH鍵チェック。なければ作成
	if [ ! -f "./${VMPREFIX}" ] || [ ! -f "./${VMPREFIX}.pub" ] ; then
		ssh-keygen -f ./${VMPREFIX} -m pem -t rsa -N "" -b 4096
	else
		chmod 600 ./${VMPREFIX}
	fi
	# SSH秘密鍵ファイルのディレクトリ決定
	tmpfile=$(stat ./${VMPREFIX} -c '%a')
	case $tmpfile in
		600 )
			SSHKEYDIR="./${VMPREFIX}"
		;;
		* )
			cp ./${VMPREFIX} "$HOME"/.ssh/
			chmod 600 "$HOME"/.ssh/${VMPREFIX}
			SSHKEYDIR="$HOME/.ssh/${VMPREFIX}"
		;;
	esac
	# github actions向けスペース
	echo "SSHKEYDIR: $SSHKEYDIR"
fi

### 基本設定
Location=japaneast #southcentralus
VMSIZE=Standard_HB120rs_v2 #Standard_HC44rs, Standard_HB120rs_v3
PBSVMSIZE=Standard_D8as_v4

### ネットワーク設定
MyAvailabilitySet=${VMPREFIX}avset01 #HPCクラスターのVMサイズ別に異なる可用性セットが必要。自動生成するように変更したため、基本変更しない
MyNetwork=${VMPREFIX}-vnet01
MySubNetwork=compute
MySubNetwork2=management # ログインノード用サブネット
ACCELERATEDNETWORKING="--accelerated-networking true" # もし問題がある場合にはflaseで利用可能。コンピュートノードのみ対象 true/false
MyNetworkSecurityGroup=${VMPREFIX}-nsg
# MACアドレスを維持するためにNICを保存するかどうかの設定
STATICMAC=false #true or false

### ユーザ設定
IMAGE="OpenLogic:CentOS-HPC:8_1:latest" #Azure URNフォーマット。OpenLogic:CentOS-HPC:8_1:latest
USERNAME=azureuser # ユーザ名: デフォルト azureuser
SSHKEYFILE="./${VMPREFIX}.pub" # SSH公開鍵ファイルを指定：デフォルトではカレントディレクトリを利用する
TAG=${VMPREFIX}=$(date "+%Y%m%d")

# 追加の永続ディスクが必要な場合、ディスクサイズ(GB)を記入する https://azure.microsoft.com/en-us/pricing/details/managed-disks/
PERMANENTDISK=0
PBSPERMANENTDISK=2048

### ログイン処理
# サブスクリプションが複数ある場合は指定しておく
#az account set -s <Subscription ID or name>
# サービスプリンシパルの利用も可能以下のパラメータとログイン処理(az login)を有効にすること
#azure_name="uuid"
#azure_password="uuid"
#azure_tenant="uuid"
# azaccount ファイルを 読み込む
source ~/.ssh/azaccount
az login --service-principal --username ${azure_name} --password ${azure_password} --tenant ${azure_tenant} --output none

# デバックオプション: DEBUG="parallel -v"
# コマンド名取得
CMDNAME=$(basename "$0")
# コマンドオプションエラー処理
if [ $# -eq 0 ]; then
	echo "実行するには1,2,3個の引数が必要です。" 1>&2
	echo "create,delete,start,stop,stop-all,stopvm #,stopvm #1 #2,startvm #1,list,remount,pingpong,addlogin,updatensg,privatenw,publicnw の引数を一つ指定する必要があります。" 1>&2
	echo "よく使うコマンド"
	echo "0. updatensg コマンド: スクリプト実行ノードのグローバルIPを利用してセキュリティグループを設定します。" 1>&2
	echo "1. create コマンド: コンピュートノードを作成します。" 1>&2
	echo "2. addlogin コマンド: login, PBSノードを作成します。" 1>&2
	echo "3. privatenw コマンド: コンピュートノード、PBSノードからグローバルIPアドレスを除きます" 1>&2
	echo "その他のコマンド"  1>&2
	echo " - stop: すべてのコンピュートノードを停止します。" 1>&2
	echo " - stop-all: すべてのコンピュートノード＋PBSノード・ログインノードもすべて停止します。" 1>&2
	echo " - stopvm <vm#>: コンピュートノードVM#のみを停止します。" 1>&2
	echo " - stopvms <start vm#> <end vm#>: コンピュートノードVM# xからVM# yまで停止します。" 1>&2
	echo " - startvm <vm#>: コンピュートノードVM#を起動します。" 1>&2
	echo " - list: VMの状況・およびマウンド状態を表示します。"  1>&2
	echo " - listip: IPアドレスアサインの状態を表示します。"  1>&2
	echo " - pingpong: すべてのノード間でpingpongを取得します。ローカルファイル result に保存します。" 1>&2
	echo " - remount: デフォルトで設定されているディレクトリの再マウントを実施します。" 1>&2
	echo " - publicnw コマンド: コンピュートノード、PBSノードからグローバルIPアドレスを再度追加します。" 1>&2
	echo " - delete: すべてのコンピュートノードを削除します。" 1>&2
	echo " - delete-all: すべてのコンピュートノード、PBSノード、ログインノードを削除します。" 1>&2
	echo " - deletevm <vm#>: 特定のコンピュートノード#のみを削除します。(PBSの設定削除などは未実装)" 1>&2
	echo " - checkfiles: ローカルで利用するスクリプトを生成します。" 1>&2
	echo " - ssh: 各VMにアクセスできます。 例：$CMDNAME ssh 1: コンピュートノード#1にSSHアクセスします。" 1>&2
	echo "====================================================================================================="
	echo " - tfsetup: Teraform環境向けセットアップ（開発中）"
	exit 1
fi

# グローバルIPアドレスの取得・処理
curl -s https://ifconfig.io > tmpip #利用しているクライアントのグローバルIPアドレスを取得
curl -s https://ipinfo.io/ip >> tmpip #代替サイトでグローバルIPアドレスを取得
curl -s https://inet-ip.info >> tmpip #代替サイトでグローバルIPアドレスを取得
# 空行削除
sed -i -e '/^$/d' tmpip > /dev/null
LIMITEDIP="$(head -n 1 ./tmpip)/32"
rm ./tmpip
echo "current your client global ip address: $LIMITEDIP. This script defines the ristricted access from this client"
LIMITEDIP2=113.40.3.153/32 #追加制限IPアドレスをCIRDで記載 例：1.1.1.0/24
echo "addtional accessible CIDR: $LIMITEDIP2"

# 必要なパッケージ： GNU parallel, jq, curlのインストール。別途、azコマンドも必須
if   [ -e /etc/debian_version ] || [ -e /etc/debian_release ]; then
    # Check Ubuntu or Debian
    if [ -e /etc/lsb-release ]; then echo "your linux distribution is: ubuntu";
		sudo apt-get install -qq -y parallel jq curl || apt-get install -qq -y parallel jq curl
    else echo "your linux distribution is: debian";
		if [[ $(hostname) =~ [a-z]*-*-*-* ]]; then echo "skipping...due to azure cloud shell";
		else sudo apt-get install -qq -y parallel jq curl || apt-get install -qq -y parallel jq curl; fi
	fi
elif [ -e /etc/fedora-release ]; then echo "your linux distribution is: fedora";
	sudo yum install --quiet -y parallel jq curl || yum install -y parallel jq curl
elif [ -e /etc/redhat-release ]; then echo "your linux distribution is: Redhat or CentOS"; 
	sudo yum install --quiet -y parallel jq curl || yum install -y parallel jq curl
fi

function getipaddresslist () {
	# $1: vmlist
	# $2: ipaddresslist
	# $3: nodelist
	# $4: renew - 新しいコンピュートノード数
	# list-ip-addresses 作成
	# Check num of parameters.
    if [ $# -gt 5 ]; then echo "error!. you can use 3 parameters."; exit 1; fi

	if [ -f ./vmlist ]; then rm ./vmlist; fi
	if [ -f ./ipaddresslist ]; then rm ./ipaddresslist; fi
	if [ -f ./nodelist ]; then rm ./nodelist; fi

	# $4があった場合には、CURRENTVM を規定する
	if [ "$4" = "renew" ]; then
		# 現在アクティブなVM数
		echo "getting current number of VMs"
		az vm list-ip-addresses -g $MyResourceGroup --query "[].virtualMachine[].{Name:name}" -o tsv --only-show-errors > tmpfile
		# コンピュートノードのみ抽出
		grep -e "${VMPREFIX}-[1-99]" ./tmpfile > ./tmpfile2
		grep -v "None" ./tmpfile2 > ./tmpfile3
		count=$(cat ./tmpfile3 | wc -l)
		echo "creating new number of VMs: $count"
		echo $((count)) > ./numofvm
		TOTALNUMVM=$(cat ./numofvm)
	else
		# 通常処理： TOTALNUMVM = MAXVM
		TOTALNUMVM=${MAXVM}
		echo "creating vmlist and ipaddresslist"
		az vm list-ip-addresses -g $MyResourceGroup --query "[].virtualMachine[].{Name:name, PublicIp:network.publicIpAddresses[0].ipAddress, PrivateIPAddresses:network.privateIpAddresses[0]}" -o tsv --only-show-errors > tmpfile
		# コンピュートノードのみ抽出
		grep -e "${VMPREFIX}-[1-99]" ./tmpfile > ./tmpfile2
		grep -v "None" ./tmpfile2 > ./tmpfile3
		count=$(cat ./tmpfile3 | wc -l)
		echo "setting up VMs: $count"
		#	while [  $((TOTALNUMVM)) -eq $((count)) ]; do
		#		az vm list-ip-addresses -g $MyResourceGroup --query "[].virtualMachine[].{Name:name, PublicIp:network.publicIpAddresses[0].ipAddress, PrivateIPAddresses:network.privateIpAddresses[0]}" -o tsv --only-show-errors > tmpfile
		#		grep "${VMPREFIX}-[1-99]" ./tmpfile > ./tmpfile2
		#		grep -v "None" ./tmpfile2 > ./tmpfile3
		#		count=$(cat ./tmpfile3 | wc -l)
		#		echo "getting list-ip-addresse... sleep 10" && sleep 10
		#	done
	fi

	# 自然番号順にソート
	sort -V ./tmpfile3 > tmpfile4

	if [ "$1" = "vmlist" ]; then
		# vmlist 作成: $1
		echo "creating vmlist"
		cut -f 1 ./tmpfile4 > vmlist
		# vmlist チェック
		numvm=$(cat ./vmlist | wc -l)
		if [ $((numvm)) -eq $((TOTALNUMVM)) ]; then
			echo "number of vmlist and maxvm are matched."
		else
			# $numvm と $TOTALNUMVM がミスマッチの場合、電源がオンでないVMが存在し、リストされるすべてのVMのIPが取れない場合になる。
			# その場合には追加で以下の処理を実施する
			echo "checking powered on number of VMs"
			az vm list -g $MyResourceGroup -d --query "[?powerState=='VM running']" -o table --only-show-errors > tmpactivevm
			grep -e "${VMPREFIX}-[1-99]" ./tmpactivevm > ./tmpactivevm2
			grep -v "None" ./tmpactivevm2 > ./activevm
			ACTIVEVM=$(cat ./activevm | wc -l)
			if [ $((numvm)) -eq $((ACTIVEVM)) ]; then
				echo "current number of vmlist is ${numvm}"
			else
				# 最終的なリスト作成ミスマッチ
				echo "number of vmlist and maxvm are unmatched!"
			fi
		fi
	fi

	if [ "$2" = "ipaddresslist" ]; then
		# ipaddresslist 作成: $2
		echo "careating IP Address list"
		cut -f 2 ./tmpfile4 > ipaddresslist
		echo "ipaddresslist file contents"
		cat ./ipaddresslist
		numip=$(cat ./ipaddresslist | wc -l)
		# ipaddresslist チェック
		if [ $((numip)) -ge $((TOTALNUMVM)) ]; then
			echo "number of ipaddresslist and maxvm are matched."
		else
			echo "checking powered on number of VMs"
			if [ $((numip)) -eq $((ACTIVEVM)) ]; then
				echo "current number of ipaddresslist is ${numip}"
			else
				echo "number of vmlist and maxvm are unmatched!"
			fi
		fi
	fi

	if [ $# -eq 3 ] && [ "$3" = "nodelist" ]; then
		# nodelist 作成: $3
		echo "careating nodelist"
		cut -f 3 ./tmpfile4 > nodelist
		echo "nodelist file contents"
		cat ./nodelist
		numnd=$(cat ./nodelist | wc -l)
		# nodelist チェック
		if [ $((numnd)) -ge $((TOTALNUMVM)) ]; then
			echo "number of nodelist and maxvm are matched."
		else
			echo "checking powered on number of VMs"
			if [ $((numnd)) -eq $((ACTIVEVM)) ]; then
				echo "current number of nodelist is ${numnd}"
			else
				echo "number of vmlist and maxvm are unmatched!"
			fi
		fi
	fi

	# 現在アクティブなVM数
#	echo "getting current number of VMs"
#	az vm list-ip-addresses -g $MyResourceGroup --query "[].virtualMachine[].{Name:name}" -o tsv > tmpfile
	# コンピュートノードのみ抽出
#	grep -e "${VMPREFIX}-[1-99]" ./tmpfile > ./tmpfile2
#	count=$(cat ./tmpfile2 | wc -l)
	
	# 自然番号順にソート
#	sort -V ./tmpfile2 > tmpfile3
#	echo "az vm list-ip-addresses..."
#	cat ./tmpfile3
	
	echo "getting current VM number - count: $count ; ACTIVEVM: $ACTIVEVM, configured MAXVM - TOTALNUMVM: $TOTALNUMVM"
#	echo $((count)) > ./numofvm
#	echo "cat numofvm..."
#	cat ./numofvm

	# テンポラリファイル削除(listip, hostsfileデバックon)
	rm ./tmpactivevm ./tmpactivevm2
	#rm ./tmpfile ./tmpfile2 ./tmpfile3 ./tmpfile4
}

# ホストファイル作成（作成のみ）
function gethostsfile () {
	echo "creating vmlist and ipaddresslist"
	az vm list-ip-addresses -g $MyResourceGroup --query "[].virtualMachine[].{Name:name, PrivateIPAddresses:network.privateIpAddresses[0]}" -o tsv > tmpfile
	# コンピュートノードのみ抽出
	grep -e "${VMPREFIX}-[1-99]" -e "${VMPREFIX}-pbs" -e "${VMPREFIX}-login" ./tmpfile > ./tmpfile2
	grep -v "None" ./tmpfile2 > ./tmpfile3
	count=$(cat ./tmpfile3 | wc -l)
	echo "setting up VMs: $count with PBS and Login Nodes"
#	while [[ $((count)) -lt $((MAXVM)) ]]; do
#		az vm list-ip-addresses -g $MyResourceGroup --query "[].virtualMachine[].{Name:name, PrivateIPAddresses:network.privateIpAddresses[0]}" -o tsv > tmpfile
#		grep -e "${VMPREFIX}-[1-99]"  -e "${VMPREFIX}-pbs" -e "${VMPREFIX}-login" ./tmpfile > ./tmpfile2
#		grep -v "None" ./tmpfile2 > ./tmpfile3
#		count=$(cat ./tmpfile3 | wc -l)	
#		echo "getting list-ip-addresse... sleep 10" && sleep 10
#	done
	# 自然番号順にソート: vmlistを先頭列にする
	sort -V ./tmpfile3 > ./tmpfile4
	# 列入れ替え：IPアドレスが先
	cat tmpfile4 | awk 'BEGIN{OFS="\t"} {print $2 "\t" $1}' > hostsfile
	echo "current hostsfile..."
	cat ./hostsfile

	# テンポラリファイル削除
	rm ./tmpfile ./tmpfile2 ./tmpfile3 ./tmpfile4
}

function checksshconnection () {
	# $1: vm1, pbs, all
	# requirement: ipaddresslist file
	# usecase: connected - Linux or, disconnected - nothing in checkssh variable
	# checkssh 変数に Linux が入ればSSH接続可能。接続不可なら 空ファイル
	unset checkssh
	if [ -f ./checkssh ]; then rm ./checkssh; fi
	case $1 in
		vm1 )
			vm1ip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-1 --query publicIps -o tsv)
			for cnt in $(seq 1 10); do
				checkssh=$(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" -t $USERNAME@"${vm1ip}" "uname")
				if [ -n "$checkssh" ]; then
					break
				fi
				echo "waiting sshd @ ${VMPREFIX}-${vm1ip}: sleep 5" && sleep 5
			done
		;;
		pbs )
			pbsvmip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-pbs --query publicIps -o tsv)
			for cnt in $(seq 1 10); do
				checkssh=$(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" -t $USERNAME@"${pbsvmip}" "uname")
				if [ -n "$checkssh" ]; then
					break
				fi
				echo "waiting sshd @ ${VMPREFIX}-${vm1ip}: sleep 5" && sleep 5
			done
		;;
		all )
			#for count in $(seq 1 $MAXVM); do
			for count in $( seq 1 $((ACTIVEVM)) ); do
				# VMが停止していてもIPアドレスが取得できている場合がある
				line=$(sed -n "${count}"P ./ipaddresslist)
				vmstate=$(az vm get-instance-view -g $MyResourceGroup --name "${VMPREFIX}"-"${count}" --query {PowerState:instanceView.statuses[1].displayStatus} -o tsv --only-show-errors)
				for cnt in $(seq 1 10); do
					checkssh=$(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" -t $USERNAME@"${line}" "hostname")
					#ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" -t $USERNAME@"${line}" "uname" >> ./checkssh
					#checkssh=$(cat ./checkssh)
					# VMが停止していれば次のVM
					if [ "$vmstate" = "VM stopped"  ]; then
						echo "${VMPREFIX}-${count} was stooped"
						break
					fi
					# SSHアクセス可能
					if [ -n "${checkssh}" ]; then 
					# && [ "$vmstate" = "VM running"  ]; then
						echo "successed ssh connection to ${VMPREFIX}-${count}"
						echo "${count}	${checkssh}	$(TZ=JST date)" >> checkssh
						break
					fi
					echo "waiting for ssh connection @ ${VMPREFIX}-${count}: sleep 5" && sleep 5
				done
			echo "count....: $count"
			echo "cat ./checkssh"
			done
			count=$(cat checkssh | wc -l)
			if [ $((count)) -eq $((MAXVM)) ]; then
				echo "getting ssh connection to all nodes."
			else
				echo "getting ssh connection to only $((count)) nodes."
			fi
		;;
	esac
}

function mountdirectory () {
	# $1: vm: vm1 or pbs
	# $2: directory: /mnt/resource/scrach or /mnt/share
	# requirement, ipaddresslist
	# case1: vm1, /mnt/resource/scratch, case2: pbs /mnt/share
	directory="$2"
	if [ "$1" = vm1 ] && [ -z "$2" ]; then
		directory="/mnt/resource/scratch"
	fi
	if [ "$1" = pbs ] && [ -z "$2" ]; then
		directory="/mnt/share"
	fi
	echo "directory: $directory"
	if [ ! -f ./ipaddresslist ]; then
		echo "error!. ./ipaddresslist is not found!"
		getipaddresslist vmlist ipaddresslist nodelist
	fi
	case $1 in
		vm1 )
			# コマンド実行判断
			vm1ip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-1 --query publicIps -o tsv --only-show-errors)
			echo "${VMPREFIX}-1's IP: $vm1ip"
			# コンピュートノードVM#1：マウント用プライベートIP 
			mountip=$(az vm show -g $MyResourceGroup --name ${VMPREFIX}-1 -d --query privateIps -o tsv --only-show-errors)
			echo "checking ssh access for vm1..."
			# 関数へ変換予定
			for count in $(seq 1 10); do
				checkssh=(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" -t "$USERNAME"@"${vm1ip}" "uname")
				if [ -n "$checkssh" ]; then
					break
				else
					checkssh=(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" -t "$USERNAME"@"${vm1ip}" "uname")
					echo "getting ssh connection. sleep 2" && sleep 2
				fi	
			done
			if [ -n "$checkssh" ]; then
				echo "${VMPREFIX}-1: $vm1ip - mount setting by ssh"
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" -t -t $USERNAME@"${vm1ip}" "sudo mkdir -p ${directory}"
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" -t -t $USERNAME@"${vm1ip}" "sudo chown $USERNAME:$USERNAME ${directory}"
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" -t -t $USERNAME@"${vm1ip}" "sudo systemctl start rpcbind && sudo systemctl start nfs-server"
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" -t -t $USERNAME@"${vm1ip}" 'sudo showmount -e'
				# 1行目を削除したIPアドレスリストを作成
				sed '1d' ./ipaddresslist > ./ipaddresslist-tmp
				# 最大何回繰り返すか？ 			ACTIVEVM=$(cat ./activevm | wc -l)
				ACTIVEVM=$(cat ./activevm | wc -l)
				#echo "${VMPREFIX}-2 to $MAXVM: mounting"
				echo "ACTIVEVM: $ACTIVEVM - ${VMPREFIX}-x VMs: mounting to {VMPREFIX}-1"
				parallel -a ipaddresslist-tmp "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} -t -t $USERNAME@{} "sudo mkdir -p ${directory}""
				parallel -a ipaddresslist-tmp "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} -t -t $USERNAME@{} "sudo chown $USERNAME:$USERNAME ${directory}""
				parallel -a ipaddresslist-tmp "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} -t -t $USERNAME@{} "sudo mount -t nfs ${mountip}:${directory} ${directory}""
				echo "current mounting status"
				parallel -a ipaddresslist-tmp "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} -t -t $USERNAME@{} "df -h | grep ${directory}""
				rm ./ipaddresslist-tmp
			else
				echo "vm1: mount setting by az vm run-command"
				for count in $(seq 2 $MAXVM) ; do
					az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-"${count}" --command-id RunShellScript --scripts "sudo mount -t nfs ${mountip}:${directory} ${directory}" --only-show-errors
					echo "sleep 60" && sleep 60
				done
			fi
			echo "end of mountdirectory vm1"
		;;
		pbs )
			# PBSノード：展開済みかチェック: pbsvmname=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-pbs --query name -o tsv)
			pbsvmip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-pbs --query publicIps -o tsv --only-show-errors)
			# PBSノード：マウントプライベートIP
			pbsmountip=$(az vm show -g $MyResourceGroup --name ${VMPREFIX}-pbs -d --query privateIps -o tsv --only-show-errors)
			echo "checking ssh access for pbs..."
			for count in $(seq 1 10); do
				checkssh=(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" -t "$USERNAME"@"${pbsvmip}" "uname")
				if [ -n "$checkssh" ]; then
					break
				else
					checkssh=$(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" -t "$USERNAME"@"${pbsvmip}" "uname")
					echo "getting ssh connection. sleep 2" && sleep 2
				fi
			done
			if [ -n "$checkssh" ]; then
				echo "pbsnode: mount setting by ssh"
				parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} -t -t $USERNAME@{} "sudo mkdir -p ${directory}""
				parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} -t -t $USERNAME@{} "sudo chown $USERNAME:$USERNAME ${directory}""
				parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} -t -t $USERNAME@{} "sudo mount -t nfs ${pbsmountip}:${directory} ${directory}""
				echo "current mounting status"
				parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} -t -t $USERNAME@{} "df -h | grep ${directory}""
			else
				echo "pbsnode: mount setting by az vm run-command"
				for count in $(seq 1 $MAXVM) ; do
					az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-"${count}" --command-id RunShellScript --scripts "sudo mount -t nfs ${pbsmountip}:${directory} ${directory}" --only-show-errors
					echo "sleep 60" && sleep 60
				done
			fi
			echo "end of mountdirectory pbs"
		;;
	esac
	echo "end mountdirectory function"
}

function basicsettings () {
	# $1: vm1, pbs, login, all
	# requirement: ipaddresslist file
	# setting for : locale, sudo, passwordless, ssh config
	# アクティブVMファイルは存在する
	if [ -s ./activevm ]; then
		ACTIVEVM=$(cat ./activevm | wc -l)
	else
		echo "error!: no activevm file here!"
	fi

	case $1 in
		vm1 )
			echo "vm1: all basic settings...."
			vm1ip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-1 --query publicIps -o tsv --only-show-errors)
			# SSHローケール設定変更
			echo "configuring /etc/ssh/config locale setting"
			locale=$(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "grep 'LC_ALL=C' /home/$USERNAME/.bashrc")
			if [ -z "$locale" ]; then
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "echo "export 'LC_ALL=C'" >> /home/$USERNAME/.bashrc"
			else
				echo "LC_ALL=C has arelady setting"
			fi
			# コンピュートノード：パスワードレス設定
			echo "コンピュートノード: confugring passwordless settings"
			if [ ! -s "./*.tfvars" ]; then
				scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./${VMPREFIX} $USERNAME@"${vm1ip}":/home/$USERNAME/.ssh/${VMPREFIX}
				scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./${VMPREFIX} $USERNAME@"${vm1ip}":/home/$USERNAME/.ssh/id_rsa
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "chmod 600 /home/$USERNAME/.ssh/id_rsa"
				scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./${VMPREFIX}.pub $USERNAME@"${vm1ip}":/home/$USERNAME/.ssh/${VMPREFIX}.pub
			else
				# terraformファイルが存在する場合、 ~/.ssh/id_rsa 利用を優先する
				scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ~/.ssh/id_rsa $USERNAME@"${vm1ip}":/home/$USERNAME/.ssh/${VMPREFIX}
				scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ~/.ssh/id_rsa $USERNAME@"${vm1ip}":/home/$USERNAME/.ssh/id_rsa
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "chmod 600 /home/$USERNAME/.ssh/id_rsa"
				scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ~/.ssh/id_rsa.pub $USERNAME@"${vm1ip}":/home/$USERNAME/.ssh/${VMPREFIX}.pub			
			fi
			# SSH Config設定
			if [ -f ./config ]; then rm ./config; fi
cat <<'EOL' >> config
Host *
StrictHostKeyChecking no
UserKnownHostsFile=/dev/null
EOL
			scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./config $USERNAME@"${vm1ip}":/home/$USERNAME/.ssh/config
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "chmod 600 /home/$USERNAME/.ssh/config"
		echo "end of basicsettings vm1"
		;;
		pbs )
			echo "pbs: all basic settings...."
			pbsvmip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-pbs --query publicIps -o tsv --only-show-errors)
			# SSHローケール設定変更
			echo "configuring /etc/ssh/config locale setting"
			locale=$(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "grep 'LC_ALL=C' /home/$USERNAME/.bashrc")
			if [ -z "$locale" ]; then
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "echo "export 'LC_ALL=C'" >> /home/$USERNAME/.bashrc"
			else
				echo "LC_ALL=C has arelady setting"
			fi
			# PBSノード：sudo設定
			echo "PBSノード: sudo 設定"
			#ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo cat /etc/sudoers | grep $USERNAME" > sudotmp
			#sudotmp=$(cat ./sudotmp)
			sudotmp=$(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo cat /etc/sudoers | grep $USERNAME")
			if [ -z "$sudotmp" ]; then
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "echo "$USERNAME ALL=NOPASSWD: ALL" | sudo tee -a /etc/sudoers"
			fi
			unset sudotmp 
			# && rm ./sudotmp
			# PBSノード：パスワードレス設定
			echo "PBSノード: confugring passwordless settings"
			if [ ! -s "./*.tfvars" ]; then
				scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./${VMPREFIX} $USERNAME@"${pbsvmip}":/home/$USERNAME/.ssh/${VMPREFIX}
				scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./${VMPREFIX} $USERNAME@"${pbsvmip}":/home/$USERNAME/.ssh/id_rsa
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "chmod 600 /home/$USERNAME/.ssh/id_rsa"
				scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./${VMPREFIX}.pub $USERNAME@"${pbsvmip}":/home/$USERNAME/.ssh/${VMPREFIX}.pub
			else
				# terraformファイルが存在する場合、 ~/.ssh/id_rsa 利用を優先する
				scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ~/.ssh/id_rsa $USERNAME@"${pbsvmip}":/home/$USERNAME/.ssh/${VMPREFIX}
				scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ~/.ssh/id_rsa $USERNAME@"${pbsvmip}":/home/$USERNAME/.ssh/id_rsa
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "chmod 600 /home/$USERNAME/.ssh/id_rsa"
				scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ~/.ssh/id_rsa.pub $USERNAME@"${pbsvmip}":/home/$USERNAME/.ssh/${VMPREFIX}.pub				
			fi
			# SSH Config設定
			if [ -f ./config ]; then rm ./config; fi
cat <<'EOL' >> config
Host *
StrictHostKeyChecking no
UserKnownHostsFile=/dev/null
EOL
			scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./config $USERNAME@"${pbsvmip}":/home/$USERNAME/.ssh/config
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "chmod 600 /home/$USERNAME/.ssh/config"
		echo "end of basicsettings pbs"
		;;
		login )
			echo "login vm: all basic settings...."
			loginvmip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-login --query publicIps -o tsv)
			# SSHローケール設定変更
			echo "configuring /etc/ssh/config locale setting"
			locale=$(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "grep 'LC_ALL=C' /home/$USERNAME/.bashrc")
			if [ -z "$locale" ]; then
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "echo "export 'LC_ALL=C'" >> /home/$USERNAME/.bashrc"
			else
				echo "LC_ALL=C has arelady setting"
			fi
			# sudo設定（スキップ）
			# ログインノード：パスワードレス設定
			echo "ログインノード: confugring passwordless settings"
			if [ ! -s "./*.tfvars" ]; then
				scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./${VMPREFIX} $USERNAME@"${loginvmip}":/home/$USERNAME/.ssh/${VMPREFIX}
				scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./${VMPREFIX} $USERNAME@"${loginvmip}":/home/$USERNAME/.ssh/id_rsa
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "chmod 600 /home/$USERNAME/.ssh/id_rsa"
				scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./${VMPREFIX}.pub $USERNAME@"${loginvmip}":/home/$USERNAME/.ssh/${VMPREFIX}.pub
			else
				# terraformファイルが存在する場合、 ~/.ssh/id_rsa 利用を優先する			
				scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ~/.ssh/id_rsa $USERNAME@"${loginvmip}":/home/$USERNAME/.ssh/${VMPREFIX}
				scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ~/.ssh/id_rsa $USERNAME@"${loginvmip}":/home/$USERNAME/.ssh/id_rsa
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "chmod 600 /home/$USERNAME/.ssh/id_rsa"
				scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ~/.ssh/id_rsa.pub $USERNAME@"${loginvmip}":/home/$USERNAME/.ssh/${VMPREFIX}.pub			
			fi
			# SSH Config設定
			if [ -f ./config ]; then rm ./config; fi
cat <<'EOL' >> config
Host *
StrictHostKeyChecking no
UserKnownHostsFile=/dev/null
EOL
			scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./config $USERNAME@"${loginvmip}":/home/$USERNAME/.ssh/config
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "chmod 600 /home/$USERNAME/.ssh/config"
		echo "end of basicsettings login"
		;;
		all )
			# SSHローケール設定変更
			echo "configuring /etc/ssh/config locale setting"
			#for count in $(seq 1 $MAXVM); do
			for count in $(seq 1 $ACTIVEVM); do
				line=$(sed -n "${count}"P ./ipaddresslist)
				locale=$(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "grep 'LC_ALL=C' /home/$USERNAME/.bashrc")
				if [ -z "$locale" ]; then
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "echo "export 'LC_ALL=C'" >> /home/$USERNAME/.bashrc"
				else
					echo "LC_ALL=C has arelady setting"
				fi
			done
			# コンピュートノード：sudo設定
			echo "コンピュートノード: sudo 設定"
			#echo "${VMPREFIX}-1 to ${MAXVM}: sudo 設定"
			echo "${VMPREFIX}-1 to ${ACTIVEVM}: sudo 設定"
			#for count in $(seq 1 $((MAXVM))); do
			for count in $(seq 1 $((ACTIVEVM)) ); do
				line=$(sed -n "${count}"P ./ipaddresslist)
				sudotmp=$(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "sudo cat /etc/sudoers | grep $USERNAME" | cut -d " " -f 1)
				#ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "sudo cat /etc/sudoers | grep $USERNAME" > sudotmp
				echo "sudotmp: $sudotmp"
				#if [ -z "$sudotmp" ]; 
				# ファイルが空(SSH不可)であるか、異なるユーザであった場合に実行
				if [ "$sudotmp" != "${USERNAME}" ]; then
					echo "sudo: setting by ssh command"
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "echo "$USERNAME ALL=NOPASSWD: ALL" | sudo tee -a /etc/sudoers"
					# 重複排除
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "sudo cp /etc/sudoers /etc/sudoers.original"
					#ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "sudo awk '!visited[$0]++' /etc/sudoers.original | sudo tee /etc/sudoers"
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "sudo uniq /etc/sudoers.original | sudo tee /etc/sudoers"
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "sudo grep $USERNAME /etc/sudoers"
					unset sudotmp
					# && rm ./sudotmp
				fi
				# SSHできない場合にaz vm run-command で実行
				checkssh=$(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "uname")
				if [ -z "$checkssh" ]; then
					echo "sudo: setting by run-command"
					az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-"${count}" --command-id RunShellScript --scripts "echo '$USERNAME ALL=NOPASSWD: ALL' | sudo tee -a /etc/sudoers" --only-show-errors
					unset sudotmp 
					#&& rm ./sudotmp
				fi
			done
			# コンピュートノード：パスワードレス設定
			#for count in $(seq 1 $((MAXVM))); do
			for count in $(seq 1 $((ACTIVEVM)) ); do
				line=$(sed -n "${count}"P ./ipaddresslist)
				echo "コンピュートノード: confugring passwordless settings"
				if [ ! -s "./*.tfvars" ]; then
					scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./${VMPREFIX} $USERNAME@"${line}":/home/$USERNAME/.ssh/${VMPREFIX}
					scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./${VMPREFIX} $USERNAME@"${line}":/home/$USERNAME/.ssh/id_rsa
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "chmod 600 /home/$USERNAME/.ssh/id_rsa"
					scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./${VMPREFIX}.pub $USERNAME@"${line}":/home/$USERNAME/.ssh/${VMPREFIX}.pub
				else
					# terraformファイルが存在する場合、 ~/.ssh/id_rsa 利用を優先する
					scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ~/.ssh/id_rsa $USERNAME@"${line}":/home/$USERNAME/.ssh/${VMPREFIX}
					scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ~/.ssh/id_rsa $USERNAME@"${line}":/home/$USERNAME/.ssh/id_rsa
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "chmod 600 /home/$USERNAME/.ssh/id_rsa"
					scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ~/.ssh/id_rsa.pub $USERNAME@"${line}":/home/$USERNAME/.ssh/${VMPREFIX}.pub				
				fi
				# SSH Config設定
				if [ -f ./config ]; then rm ./config; fi
cat <<'EOL' >> config
Host *
StrictHostKeyChecking no
UserKnownHostsFile=/dev/null
EOL
				scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./config $USERNAME@"${line}":/home/$USERNAME/.ssh/config
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "chmod 600 /home/$USERNAME/.ssh/config"
			done
		echo "end of basicsettings all (all compute nodes)"
		;;
	esac
	echo "end of basicsettings function"
}

function pbssetup () {
	# $1: vm1, pbs, login, all
	# $2: copy, install, setup, config(queue setting), uninstall(under dev...)
	# $3: ファイル指定
	true
}

#### =====================================================================================================================================================
case $1 in
	create )
		# 引数があったら終了
	    if [ $# -gt 1 ]; then echo "error!. you can use no parameter(s) here ."; exit 1; fi
		# 全体環境作成
		az group create --resource-group $MyResourceGroup --location $Location --tags "$TAG" --output none
		# ネットワークチェック
		tmpnetwork=$(az network vnet show -g $MyResourceGroup --name $MyNetwork --query id -o tsv --only-show-errors)
		echo "current netowrk id: $tmpnetwork"
		if [ -z "$tmpnetwork" ] ; then
			az network vnet create -g $MyResourceGroup -n $MyNetwork --address-prefix 10.0.0.0/22 --subnet-name $MySubNetwork --subnet-prefix 10.0.0.0/24 --output none
		fi
		# NSGがあるかどうかチェック
		checknsg=$(az network nsg show --name $MyNetworkSecurityGroup -g $MyResourceGroup --query name -o tsv --only-show-errors)
		if [ -z "$checknsg" ]; then
			# 既存NSGがなければ作成
			az network nsg create --name $MyNetworkSecurityGroup -g $MyResourceGroup -l $Location --tags "$TAG" --output none
			az network nsg rule create --name ssh --nsg-name $MyNetworkSecurityGroup -g $MyResourceGroup --access allow --protocol Tcp --direction Inbound \
				--priority 1000 --source-address-prefix "$LIMITEDIP" --source-port-range "*" --destination-address-prefix "*" --destination-port-range 22 --output none
			az network nsg rule create --name ssh2 --nsg-name $MyNetworkSecurityGroup -g $MyResourceGroup --access allow --protocol Tcp --direction Inbound \
				--priority 1010 --source-address-prefix $LIMITEDIP2 --source-port-range "*" --destination-address-prefix "*" --destination-port-range 22 --output none
		else
			# NSGがあれば、アップデート
			az network nsg rule create --name ssh --nsg-name $MyNetworkSecurityGroup -g $MyResourceGroup --access allow --protocol Tcp --direction Inbound \
				--priority 1000 --source-address-prefix "$LIMITEDIP" --source-port-range "*" --destination-address-prefix "*" --destination-port-range 22 --output none
			az network nsg rule create --name ssh2 --nsg-name $MyNetworkSecurityGroup -g $MyResourceGroup --access allow --protocol Tcp --direction Inbound \
				--priority 1010 --source-address-prefix $LIMITEDIP2 --source-port-range "*" --destination-address-prefix "*" --destination-port-range 22 --output none
		fi

		# 可用性セットの処理
		#checkavset=$(az vm availability-set list-sizes --name ${VMPREFIX}avset01 -g $MyResourceGroup -o tsv | head -n 1 | cut -f 3)
		checkavset=$(az vm availability-set list-sizes --name ${VMPREFIX}avset01 -g $MyResourceGroup -o tsv --only-show-errors | grep ${VMSIZE} | cut -f 3)
		if [ -z "$checkavset" ]; then
			az vm availability-set create --name $MyAvailabilitySet -g $MyResourceGroup -l $Location --tags "$TAG" --output none
		else
			echo "checkavset : $checkavset - current cluster vmsize or no assignment or general sku."
			echo "your VMSIZE: $VMSIZE"
			# ${VMPREFIX}avset01: 同じVMサイズの場合、可用性セットを利用する
			if [ ${VMSIZE} = "$checkavset" ]; then
				# 既に avset01 が利用済みの場合で VMSIZE が異なれば、以下実行
				echo "use same avset: ${VMPREFIX}avset01"
				MyAvailabilitySet="${VMPREFIX}avset01"
			else
				# 可用性セット 1+2~10, 10クラスタ想定
				for count in $(seq 2 10); do
					checkavsetnext=$(az vm availability-set list-sizes --name ${VMPREFIX}avset0"${count}" -g $MyResourceGroup -o tsv --only-show-errors | wc -l)
					# 0 の場合、この可用性セットは利用されていない
					if [ $((checkavsetnext)) -eq 0 ]; then
						echo "${VMPREFIX}avset0${count} is nothing. assining a new avaiability set: ${VMPREFIX}avset0${count}"
						MyAvailabilitySet="${VMPREFIX}avset0${count}"
						az vm availability-set create --name "$MyAvailabilitySet" -g $MyResourceGroup -l $Location --tags "$TAG" --output none
						break
					# 1 の場合、可用性セットは利用中
					elif [ $((checkavsetnext)) -eq 1 ]; then
						echo "${VMPREFIX}avset0${count} has already used."
					# 多数 の場合、一般SKUを利用。利用中か不明だが、既存可用性セットとして再利用可能
					elif [ $((checkavsetnext)) -gt 5 ]; then
						# check avset: ${VMPREFIX}avset01
						checkavset2=$(az vm availability-set list-sizes --name ${VMPREFIX}avset01 -g $MyResourceGroup -o tsv --only-show-errors | cut -f 3 | wc -l)
						if [ $((checkavset2)) -gt 5 ]; then
							echo "use existing availalibty set: ${VMPREFIX}avset01"
							MyAvailabilitySet=${VMPREFIX}avset01
							break
						else
							echo "${VMPREFIX}avset0${count} is belong to general sku."
							MyAvailabilitySet="${VMPREFIX}avset0${count}"
							az vm availability-set create --name "$MyAvailabilitySet" -g $MyResourceGroup -l $Location --tags "$TAG" --output none
							break
						fi
					fi
					# 未使用の場合、すべてのサイズがリストされる. ex. 379　この可用性セットは利用可能
				done
			fi
		fi

		# VM作成
		for count in $(seq 1 $MAXVM); do
			# echo "creating nic # $count"
			if [ ${STATICMAC} = "true" ]; then
				az network nic create --name ${VMPREFIX}-"${count}"VMNic --resource-group $MyResourceGroup --vnet-name $MyNetwork --subnet $MySubNetwork --network-security --accelerated-networking true --only-show-errors
				echo "creating VM # ${count} with static nic"
				# $ACCELERATEDNETWORKING: にはダブルクォーテーションはつけない
				az vm create -g $MyResourceGroup -l $Location --name ${VMPREFIX}-"${count}" --size $VMSIZE --availability-set "$MyAvailabilitySet" --nics ${VMPREFIX}-"${count}"VMNic --image $IMAGE --admin-username $USERNAME --ssh-key-values $SSHKEYFILE --no-wait --tags "$TAG" -o none
			fi
			echo "creating VM # $count with availability set: $MyAvailabilitySet"
			# $ACCELERATEDNETWORKING: にはダブルクォーテーションはつけない
			az vm create \
				--resource-group $MyResourceGroup --location $Location \
				--name ${VMPREFIX}-"${count}" \
				--size $VMSIZE --availability-set "$MyAvailabilitySet" \
				--vnet-name $MyNetwork --subnet $MySubNetwork \
				--nsg $MyNetworkSecurityGroup --nsg-rule SSH $ACCELERATEDNETWORKING \
				--image $IMAGE \
				--admin-username $USERNAME --ssh-key-values $SSHKEYFILE \
				--no-wait --tags "$TAG" -o table --only-show-errors
		done

		# 永続ディスクが必要な場合に設定可能
		if [ $((PERMANENTDISK)) -gt 0 ]; then
			az vm disk attach --new -g $MyResourceGroup --size-gb $PERMANENTDISK --sku Premium_LRS --vm-name ${VMPREFIX}-1 --name ${VMPREFIX}-1-disk0 -o table --only-show-errors
		fi

		# IPアドレスが取得できるまで停止する
		if [ $((MAXVM)) -ge 20 ]; then
			echo "sleep 180" && sleep 180
		else
			echo "sleep 90" && sleep 90
		fi

		# 停止：VMがすべて起動するまで待ち
		# すべてのコンピュートVM数は 1 to MAXVM
		#for count in $(seq 1 $MAXVM); do
		for count in $(seq 1 $ACTIVEVM); do
			vmstate=$(az vm get-instance-view -g $MyResourceGroup --name "${VMPREFIX}"-"${count}" --query {PowerState:instanceView.statuses[1].displayStatus} -o tsv --only-show-errors)
			while [ "$vmstate" != "VM running"  ]; do
				echo "wating for VM: ${VMPREFIX}-${count} was running"
				sleep 10
				vmstate=$(az vm get-instance-view -g $MyResourceGroup --name "${VMPREFIX}"-"${count}" --query {PowerState:instanceView.statuses[1].displayStatus} -o tsv --only-show-errors)
			done
		echo "count....$count"
		done

		# vmlist and ipaddress 作成
		getipaddresslist vmlist ipaddresslist

		# すべてのVMにSSH可能なら checkssh に変数を代入
		checksshconnection all

		# all computenodes: basicsettings - locale, sudo, passwordless, sshd
		basicsettings all

		# fstab設定
		echo "setting fstab"
		mountip=$(az vm show -g $MyResourceGroup --name ${VMPREFIX}-1 -d --query privateIps -o tsv --only-show-errors)
		if [ ! -s ./checkfstab ]; then 
			if [ -n "$checkssh" ]; then
				echo "${VMPREFIX}-${count}: configuring fstab by ssh"
				#ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@${line} -t -t "sudo sed -i -e '/azure_resource-part1/d' /etc/fstab"
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t 'sudo umount /dev/disk/cloud/azure_resource-part1'
				# 重複していないかチェック
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "sudo grep ${mountip}:/mnt/resource/scratch /etc/fstab" > checkfstab
				checkfstab=$(cat checkfstab | wc -l)
				if [ $((checkfstab)) -ge 2 ]; then 
					echo "deleting dupulicated settings...."
					#ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "sudo sed -i -e '/${mountip}:\/mnt\/resource/d' /etc/fstab"
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "sudo sed -i -e '$ a ${mountip}:/mnt/resource/scratch    /mnt/resource/scratch    xfs    defaults    0    0' /etc/fstab"
				elif [ $((checkfstab)) -eq 1 ]; then
					echo "correct fstab setting"
				elif [ $((checkfstab)) -eq 0 ]; then
					echo "fstab missing: no /mnt/resource/scratch here!"
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "sudo sed -i -e '$ a ${mountip}:/mnt/resource/scratch    /mnt/resource/scratch    xfs    defaults    0    0' /etc/fstab"
				fi
			else
				# fstab 設定: az vm run-command
				echo "${VMPREFIX}-${count}: configuring fstab by az vm run-command"
				#az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-"${count}" --command-id RunShellScript --scripts "sudo sed -i -e '/azure_resource-part1/d' /etc/fstab"
				#az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-"${count}" --command-id RunShellScript --scripts 'sudo umount /dev/disk/cloud/azure_resource-part1'
				# 重複していないかチェック
				az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-"${count}" --command-id RunShellScript --scripts "sudo grep "${mountip}:/mnt/resource/scratch" /etc/fstab" > checkfstab
				checkfstab=$(cat checkfstab | wc -l)
				if [ $((checkfstab)) -ge 2 ]; then
					echo "deleting dupulicated settings...."
					az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-"${count}" --command-id RunShellScript \
						--scripts "sudo sed -i -e '/${mountip}:\/mnt\/resource/d' /etc/fstab" --only-show-errors
					az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-"${count}" --command-id RunShellScript \
						--scripts "sudo sed -i -e '$ a ${mountip}:/mnt/resource/scratch    /mnt/resource/scratch    xfs    defaults    0    0' /etc/fstab" --only-show-errors
				elif [ $((checkfstab)) -eq 1 ]; then
					echo "correct fstab setting"
				elif [ $((checkfstab)) -eq 0 ]; then
					echo "fstab missing: no /mnt/resource/scratch here!"
					az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-"${count}" --command-id RunShellScript \
						--scripts "sudo sed -i -e '$ a ${mountip}:/mnt/resource/scratch    /mnt/resource/scratch    xfs    defaults    0    0' /etc/fstab" --only-show-errors
				fi
			fi
			rm ./checkfstab
		fi

		echo "setting up vm1 nfs server"
		vm1ip=$(head -n 1 ./ipaddresslist)
		for count in $(seq 1 15); do
			checkssh=$(ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 5' -i "${SSHKEYDIR}" -t $USERNAME@"${vm1ip}" "uname")
			if [ -n "$checkssh" ]; then
				break
			fi
			echo "waiting sshd @ ${VMPREFIX}-1: sleep 10" && sleep 10
		done
		echo "checkssh connectiblity for ${VMPREFIX}-1: $checkssh"
		if [ -z "$checkssh" ]; then
			az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-1 --command-id RunShellScript \
				--scripts "sudo yum install --quiet -y nfs-utils epel-release && echo '/mnt/resource/scratch *(rw,no_root_squash,async)' >> /etc/exports" --only-show-errors
			az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-1 --command-id RunShellScript --scripts "sudo yum install --quiet -y htop" --only-show-errors
			sleep 5
			az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-1 --command-id RunShellScript --scripts "sudo mkdir -p /mnt/resource/scratch" --only-show-errors
			az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-1 --command-id RunShellScript --scripts "sudo chown ${USERNAME}:${USERNAME} /mnt/resource/scratch" --only-show-errors
			az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-1 --command-id RunShellScript --scripts "sudo systemctl start rpcbind && sudo systemctl start nfs-server" --only-show-errors
			#az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-1 --command-id RunShellScript --scripts "sudo systemctl enable rpcbind && sudo systemctl enable nfs-server" --only-show-errors
		else
			# SSH設定が高速なため、checkssh が有効な場合、SSHで実施
			echo "${VMPREFIX}-1: sudo 設定"
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "sudo cat /etc/sudoers | grep $USERNAME" > sudotmp
			if [ -z "$sudotmp" ]; then
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "echo "$USERNAME ALL=NOPASSWD: ALL" | sudo tee -a /etc/sudoers"
			fi
			unset sudotmp && rm ./sudotmp
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "sudo cat /etc/sudoers | grep $USERNAME"
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "sudo yum install --quiet -y nfs-utils epel-release"
			# アフターインストール：epel-release
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "sudo yum install --quiet -y htop"
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "echo '/mnt/resource/scratch *(rw,no_root_squash,async)' | sudo tee /etc/exports"
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "sudo mkdir -p /mnt/resource/scratch"
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "sudo chown ${USERNAME}:${USERNAME} /mnt/resource/scratch"
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "sudo systemctl start rpcbind && sudo systemctl start nfs-server"
			#ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "sudo systemctl enable rpcbind && sudo systemctl enable nfs-server"
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "sudo showmount -e"
		fi

		# 高速化のためにSSHで一括設定しておく
		echo "ssh parallel settings: nfs client"
		# 1行目を削除したIPアドレスリストを作成
		sed '1d' ./ipaddresslist > ./ipaddresslist-tmp
		parallel -a ipaddresslist-tmp "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 5' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo yum install --quiet -y nfs-utils epel-release""
		parallel -a ipaddresslist-tmp "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 5' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo yum install --quiet -y htop""
		parallel -a ipaddresslist-tmp "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 5' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo mkdir -p /mnt/resource/scratch""
		parallel -a ipaddresslist-tmp "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 5' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo chown $USERNAME:$USERNAME /mnt/resource/scratch""
		parallel -a ipaddresslist-tmp "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 5' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo mount -t nfs ${mountip}:/mnt/resource/scratch /mnt/resource/scratch""
		rm ./ipaddresslist-tmp

		# NFSサーバ・マウント設定
		#echo "${VMPREFIX}-2 to ${MAXVM}: mouting VM#1"
		echo "${VMPREFIX}-2 to ${ACTIVEVM}: mouting VM#1"
		mountdirectory vm1
		#echo "${VMPREFIX}-2 to ${MAXVM}: end of mouting ${mountip}:/mnt/resource/scratch"
		echo "${VMPREFIX}-2 to ${ACTIVEVM}: end of mouting ${mountip}:/mnt/resource/scratch"

		# ホストファイル事前バックアップ（PBSノード追加設定向け）
		echo "backup original hosts file"
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 5' -i ${SSHKEYDIR} $USERNAME@{} "sudo cp /etc/hosts /etc/hosts.original""

		# PBSノードがなければ終了
		pbsvmname=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-pbs --query name -o tsv --only-show-errors)
		if [ -z "$pbsvmname" ]; then
			echo "no PBS node here! Finished Compute Node creation."
			exit 0
		fi

### ===========================================================================
		# PBSノード：マウント設定
		echo "pbsnode: nfs server @ ${VMPREFIX}-pbs"
		mountdirectory pbs
		#echo "${VMPREFIX}-1 to ${MAXVM}: end of mouting ${pbsmountip}:/mnt/share"
		echo "${VMPREFIX}-1 to ${ACTIVEVM}: end of mouting ${pbsmountip}:/mnt/share"

		# PBSノードがある場合にのみ、ホストファイル作成
		# ホストファイル作成準備：既存ファイル削除
		#if [ -f ./vmlist ]; then rm ./vmlist; echo "recreating a new vmlist"; fi
		#if [ -f ./hostsfile ]; then rm ./hostsfile; echo "recreating a new hostsfile"; fi
		#if [ -f ./nodelist ]; then rm ./nodelist; echo "recreating a new nodelist"; fi
		# ホストファイル作成
		gethostsfile
		#getipaddresslist vmlist ipaddresslist nodelist
		# PASTEコマンドでホストファイル作成
		#paste ./nodelist ./vmlist > ./hostsfile

		#az vm list-ip-addresses -g $MyResourceGroup --query "[].virtualMachine.{VirtualMachine:name,PrivateIPAddresses:network.privateIpAddresses[0]}" -o tsv > tmphostsfile
		# プロジェクトに無関係なノードは除外する
		#grep -e "${VMPREFIX}-[1-99]" -e "${VMPREFIX}-pbs" -e "${VMPREFIX}-login" ./tmphostsfile > ./tmphostsfile2
		# 自然な順番でソートする
		#sort -V ./tmphostsfile2 > hostsfile
		# vmlist 取り出し：1列目
		#cut -f 1 ./hostsfile > vmlist
		# nodelist 取り出し：2列目
		#cut -f 2 ./hostsfile > nodelist
		# ダブルクォーテーション削除: sed -i -e "s/\"//g" ./tmphostsfile
		# ファイルの重複行削除。列は2列まで想定: cat  ./tmphostsfile2 | awk '!colname[$1]++{print $1, "\t", $2}' > ./hostsfile
		#echo "show current hostsfile"
		#cat ./hostsfile
		# テンポラリファイル削除
		#rm ./tmphostsfile ./tmphostsfile2

		# PBSノード：ホストファイル転送・更新
		checkssh=$(ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i "${SSHKEYDIR}" -t $USERNAME@"${pbsvmip}" "uname")
		if [ -n "$checkssh" ]; then
			# ssh成功すれば実施
			echo "${VMPREFIX}-pbs: updating hosts file by ssh"
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "rm /home/$USERNAME/hostsfile"
			scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./hostsfile $USERNAME@"${pbsvmip}":/home/$USERNAME/
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo cp /etc/hosts.original /etc/hosts"
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "cat /home/$USERNAME/hostsfile | sudo tee -a /etc/hosts"
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo cat /etc/hosts | grep ${VMPREFIX}"
		else
			# SSH失敗した場合、az vm run-commandでのホストファイル転送・更新
			echo "${VMPREFIX}-pbs: updating hosts file by az vm running command"
			# ログインノードIPアドレス取得：空なら再取得
			loginvmip=$(cat ./loginvmip)
			if [ -n "$loginvmip" ]; then
				loginvmip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-login --query publicIps -o tsv --only-show-errors)
			fi
			echo "loginvmip: $loginvmip"
			echo "PBSノード: ssh: ホストファイル転送 local to login node"
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "rm /home/$USERNAME/hostsfile"
			scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./hostsfile $USERNAME@"${loginvmip}":/home/$USERNAME/
			scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./${VMPREFIX} $USERNAME@"${loginvmip}":/home/$USERNAME/${VMPREFIX}
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "chmod 600 /home/$USERNAME/${VMPREFIX}"
			echo "PBSノード: ssh: ホストファイル転送 ログインノード to PBSノード"
			az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-pbs --command-id RunShellScript --scripts "scp -o StrictHostKeyChecking=no -i /home/$USERNAME/${VMPREFIX} $USERNAME@${loginprivateip}:/home/$USERNAME/hostsfile /home/$USERNAME/" --only-show-errors
			echo "PBSノード: az: ホストファイル更新"
			az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-pbs --command-id RunShellScript --scripts "sudo cp /etc/hosts.original /etc/hosts" --only-show-errors
			# az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-pbs --command-id RunShellScript --scripts "cat /home/$USERNAME/hostsfile | sudo tee -a /etc/hosts" --only-show-errors
			az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-pbs --command-id RunShellScript --scripts "cat /etc/hosts" --only-show-errors
		fi
		# コンピュートノード：ホストファイル転送・更新
		echo "copy hostsfile to all compute nodes"
		count=0
#		for count in $(seq 1 $MAXVM); do
		for count in $(seq 1 $ACTIVEVM); do
			line=$(sed -n "${count}"P ./ipaddresslist)
			# ログインノードへのSSHアクセスチェック
			loginvmip=$(cat ./loginvmip)
			if [ -n "$loginvmip" ]; then
				loginvmip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-login --query publicIps -o tsv --only-show-errors)
			fi
			echo "loginvmip: $loginvmip"
			# コンピュートノードへの直接SSHアクセスチェック
			vm1ip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-1 --query publicIps -o tsv --only-show-errors)
			checkssh=$(ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "uname")
			echo "checkssh: $checkssh"
			if [ -n "$checkssh" ]; then
				#echo "${VMPREFIX}-1 to ${MAXVM}: updating hostsfile by ssh(direct)"
				echo "${VMPREFIX}-1 to ${ACTIVEVM}: updating hostsfile by ssh(direct)"
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "rm /home/$USERNAME/hostsfile"
				scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./hostsfile $USERNAME@"${line}":/home/$USERNAME/
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "sudo cp /etc/hosts.original /etc/hosts"
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "sudo cp /home/$USERNAME/hostsfile /etc/hosts"
				echo "${VMPREFIX}-${count}: show new hosts file"
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "sudo cat /etc/hosts | grep ${VMPREFIX}"
			else
				# ログインノード経由で設定
				checkssh2=$(ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "uname")
				if [ -n "$checkssh2" ]; then
					#echo "${VMPREFIX}-1 to ${MAXVM}: updating hostsfile by ssh(via login node)"
					echo "${VMPREFIX}-1 to ${ACTIVEVM}: updating hostsfile by ssh(via login node)"
					# 多段SSH
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${line} -t -t "rm /home/$USERNAME/hostsfile""
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "scp -o StrictHostKeyChecking=no -i ${SSHKEYDIR} ./hostsfile $USERNAME@${line}:/home/$USERNAME/"
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${line} -t -t "sudo cp /etc/hosts.original /etc/hosts""
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${line} -t -t "sudo cp /home/$USERNAME/hostsfile /etc/hosts""
					echo "${VMPREFIX}-${count}: show new hosts file"
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${line} -t -t "sudo cat /etc/hosts | grep ${VMPREFIX}""
				else
					# SSHできないため、az vm run-commandでのホストファイル転送・更新
					echo "${VMPREFIX}-${count}: updating hosts file by az vm running command"
					# ログインノードIPアドレス取得：取得済み
					echo "loginvmip: $loginvmip"
					echo "ローカル: ssh: ホストファイル転送 transfer login node"
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "rm /home/$USERNAME/hostsfile"
					scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./hostsfile $USERNAME@"${loginvmip}":/home/$USERNAME/
					scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./${VMPREFIX} $USERNAME@"${loginvmip}":/home/$USERNAME/
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "chmod 600 /home/$USERNAME/${VMPREFIX}"
					# ログインプライベートIPアドレス取得：すでに取得済み
					#loginprivateip=$(az vm show -g $MyResourceGroup --name ${VMPREFIX}-login -d --query privateIps -o tsv --only-show-errors)
					#for count2 in $(seq 1 $MAXVM); do
					for count2 in $(seq 1 $ACTIVEVM); do
						# ログインノードへはホストファイル転送済み
						echo "コンピュートノード： az: ホストファイル転送 login to compute node"
						az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-"${count2}" --command-id RunShellScript --scripts "scp -o StrictHostKeyChecking=no -i /home/$USERNAME/${VMPREFIX} $USERNAME@${loginprivateip}:/home/$USERNAME/hostsfile /home/$USERNAME/" --only-show-errors
						echo "コンピュートノード： az: ホストファイル更新"
						az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-"${count2}" --command-id RunShellScript --scripts "sudo cp /etc/hosts.original /etc/hosts" --only-show-errors
						az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-"${count2}" --command-id RunShellScript --scripts "sudo cp /home/$USERNAME/hostsfile /etc/hosts" --only-show-errors
						az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-"${count2}" --command-id RunShellScript --scripts "sudo cat /etc/hosts" --only-show-errors
					done
				fi
			fi
		done
		# ホストファイル更新完了
		echo "end of hostsfile update"
		# 追加ノードのPBS設定：実装済み。追加の場合、ダイレクトSSHが必須
### ===========================================================================
		# ローカルにopenPBSファイルがあるのは前提
		# ダウンロード、およびMD5チェック
		count=0
		if [ -f ./md5executionremote ]; then rm ./md5executionremote; fi
		if [ -f ./md5executionremote2 ]; then rm ./md5executionremote2; fi
		# CentOS バージョンチェック(PBSノードとコンピュートノードが同じOSバージョンの想定)
		centosversion=$(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "cat /etc/redhat-release" | cut  -d " " -f 4)
		echo "centosversion: $centosversion"
		# CentOS 7.x か 8.xか判別する
		case $centosversion in
			7.?.* )
				# CentOS 7.xの場合
				# PBSノード：openPBSクライアントコピー
				echo "CentOS7.x: copy openpbs-execution-20.0.1-0.x86_64.rpm to all compute nodes"
				parallel -a ipaddresslist "scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 360' -i ${SSHKEYDIR} ./openpbs-execution-20.0.1-0.x86_64.rpm $USERNAME@{}:/home/$USERNAME/"
				#for count in $(seq 1 $MAXVM); do
				for count in $(seq 1 $ACTIVEVM); do
					line=$(sed -n "${count}"P ./ipaddresslist)
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "md5sum /home/$USERNAME/openpbs-execution-20.0.1-0.x86_64.rpm | cut -d ' ' -f 1" > md5executionremote
					md5executionremote=$(cat ./md5executionremote)
					echo "md5executionremote: $md5executionremote"
				for cnt in $(seq 1 3); do
					if [ "$md5executionremote" == "$md5execution" ]; then
					# 固定ではうまくいかない
					# if [ "$md5executionremote" != "59f5110564c73e4886afd579364a4110" ]; then
						ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "rm /home/$USERNAME/openpbs-execution-20.0.1-0.x86_64.rpm"
						scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./openpbs-execution-20.0.1-0.x86_64.rpm $USERNAME@"${line}":/home/$USERNAME/openpbs-execution-20.0.1-0.x86_64.rpm
						ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "md5sum /home/$USERNAME/openpbs-execution-20.0.1-0.x86_64.rpm | cut -d ' ' -f 1" > md5executionremote
						md5executionremote=$(cat ./md5executionremote)
						echo "md5executionremote: $md5executionremote"
						echo "md5executionremote2: $md5executionremote2"
						for cnt2 in $(seq 1 3); do
							echo "checking md5...: $cnt2"
							if [ "$md5executionremote2" != "$md5execution" ]; then
							# 固定ではうまくいかない
							# if [ "$md5executionremote2" != "59f5110564c73e4886afd579364a4110" ]; then
								ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "rm /tmp/openpbs-execution-20.0.1-0.x86_64.rpm"
								ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "wget -q $baseurl/openpbs-execution-20.0.1-0.x86_64.rpm -O /tmp/openpbs-execution-20.0.1-0.x86_64.rpm"
								ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "md5sum /tmp/openpbs-execution-20.0.1-0.x86_64.rpm  | cut -d ' ' -f 1" > md5executionremote2
								md5executionremote2=$(cat ./md5executionremote2)
								ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "cp /tmp/openpbs-execution-20.0.1-0.x86_64.rpm /home/$USERNAME/openpbs-execution-20.0.1-0.x86_64.rpm"
								echo "md5executionremote2: $md5executionremote2"
							else
								echo "match md5 by md5executionremote2"
								md5executionremote2=$(cat ./md5executionremote2)
								break
							fi
						done
				else
					echo "match md5 by md5executionremote"
					md5executionremote=$(cat ./md5executionremote)
					break
				fi
			done
		done
			;;
			8.?.* )
				echo "skip check md5"
				# PBSノード：openPBSクライアントコピー
				echo "CentOS8.x: copy openpbs-execution-20.0.1-0.x86_64.rpm to all compute nodes"
				# ライブラリ対応 
				parallel -a ipaddresslist "scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 360' -i ${SSHKEYDIR} ./openpbs_20.0.1.centos_8/hwloc-libs-1.11.8-4.el7.x86_64.rpm $USERNAME@{}:/home/$USERNAME/"
				parallel -a ipaddresslist "scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 360' -i ${SSHKEYDIR} ./openpbs_20.0.1.centos_8/openpbs-execution-20.0.1-0.x86_64.rpm $USERNAME@{}:/home/$USERNAME/"
			;;
			* )
				echo "skipped PBSノード：openPBSクライアントコピー"
			;;
		esac

		if [ -f ./md5executionremote ]; then rm ./md5executionremote; fi
		if [ -f ./md5executionremote2 ]; then rm ./md5executionremote2; fi

		# OpenPBSクライアント：インストール準備
		echo "centosversion: $centosversion"
		case $centosversion in
			7.?.* )
				echo "CentOS 7.x: confuguring all compute nodes requisites"
				parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@{} -t -t 'sudo yum install --quiet -y hwloc-libs libICE libSM'"
				parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t 'sudo yum install --quiet -y libnl3'"
				echo "installing libnl3"
			;;
			8.?.* )
				echo "CentOS 8.x: confuguring all compute nodes requisites"
				parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@{} -t -t 'sudo dnf install --quiet -y hwloc-libs-1.11.8-4.el7.x86_64.rpm'"
				parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@{} -t -t 'sudo dnf install --quiet -y libICE libSM'"
				parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t 'sudo dnf install --quiet -y libnl3'"
			;;
			* )
				echo "skipped コンピュートノード：openPBSクライアントコピー"
			;;
		esac

		# OpenPBSクライアント：インストール - openpbs-execution-20.0.1-0.x86_64.rpm
		echo "CentOS 7.x and 8.x: installing openpbs-execution-20.0.1-0.x86_64.rpm"
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo yum install --quiet -y /home/$USERNAME/openpbs-execution-20.0.1-0.x86_64.rpm""
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t 'sudo rpm -aq | grep openpbs'"

		# OpenPBS 設定
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t 'sudo /opt/pbs/libexec/pbs_habitat'"
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t 'sudo /opt/pbs/libexec/pbs_postinstall'"

		# OpenPBSクライアント：pbs.confファイル生成
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo sed -i -e 's/PBS_START_MOM=0/PBS_START_MOM=1/g' /etc/pbs.conf""
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo sed -i -e s/CHANGE_THIS_TO_PBS_SERVER_HOSTNAME/${VMPREFIX}-pbs/g /etc/pbs.conf""
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo cat /etc/pbs.conf""

		# OpenPBSクライアント：パーミッション設定
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t 'sudo chmod 4755 /opt/pbs/sbin/pbs_iff'"
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t 'sudo chmod 4755 /opt/pbs/sbin/pbs_rcp'"

		# OpenPBSクライアント：/var/spool/pbs/mom_priv/config コンフィグ設定
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo sed -i -e s/CHANGE_THIS_TO_PBS_SERVER_HOSTNAME/${VMPREFIX}-pbs/g /var/spool/pbs/mom_priv/config""
		#for count in $(seq 1 $MAXVM) ; do
		for count in $(seq 1 $ACTIVEVM) ; do
			line=$(sed -n "${count}"P ./ipaddresslist)
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "sudo sed -i -e s/CHANGE_THIS_TO_PBS_SERVER_HOSTNAME/${VMPREFIX}-pbs/g /var/spool/pbs/mom_priv/config"
		done

		#rm ./centosversion
### ===========================================================================
		# PBSプロセス起動
		# PBSノード起動＆$USERNAME環境変数設定
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "grep pbs.sh /home/azureuser/.bashrc" > ./pbssh
		pbssh=$(cat ./pbssh)
		if [ -z "$pbssh" ]; then
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "yes | sudo /etc/init.d/pbs start"
		fi
		# OpenPBSクライアントノード起動＆$USERNAME環境変数設定
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t 'sudo /etc/init.d/pbs start'"
		vm1ip=$(head -n 1 ./ipaddresslist)
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "grep pbs.sh /home/azureuser/.bashrc" > ./pbssh
		pbssh=$(cat ./pbssh)
		if [ -z "$pbssh" ]; then
			parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t 'echo 'source /etc/profile.d/pbs.sh' >> $HOME/.bashrc'"
		fi
		rm ./pbssh
		echo "finished to set up additonal login and PBS node"
### ===========================================================================
		# PBSジョブスケジューラセッティング
		echo "configpuring PBS settings"
		rm ./setuppbs.sh
		#for count in $(seq 1 $MAXVM); do
		for count in $(seq 1 $ACTIVEVM); do
			echo "/opt/pbs/bin/qmgr -c "create node ${VMPREFIX}-${count}"" >> setuppbs.sh
		done
		sed -i -e "s/-c /-c '/g" setuppbs.sh
		sed -i -e "s/$/\'/g" setuppbs.sh
		echo "setuppbs.sh: $(cat ./setuppbs.sh)"
		scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./setuppbs.sh $USERNAME@"${pbsvmip}":/home/$USERNAME/setuppbs.sh
		# SSH鍵登録
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo cp /root/.ssh/authorized_keys /root/.ssh/authorized_keys.old"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo cp /home/$USERNAME/.ssh/authorized_keys /root/.ssh/authorized_keys"
		# ジョブスケジューラセッティング
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" root@"${pbsvmip}" -t -t "bash /home/$USERNAME/setuppbs.sh"
		rm ./setuppbs.sh
	
	echo "Finished Compute Node creation"
	exit 0
	;;
#### =====================================================================================================================================================
	# ログインノード、PBSノードを作成します。
	addlogin )
		# 引数があったら終了
	    if [ $# -gt 1 ]; then echo "error!. you can use no parameter(s) here ."; exit 1; fi
		# 既存ネットワークチェック
		tmpsubnetwork=$(az network vnet subnet show -g $MyResourceGroup --name $MySubNetwork2 --vnet-name $MyNetwork --query id -o none)
		echo "current subnetowrk id: $tmpsubnetwork"
		if [ -z "$tmpsubnetwork" ]; then
			# mgmtサブネット追加
			az network vnet subnet create -g $MyResourceGroup --vnet-name $MyNetwork -n $MySubNetwork2 --address-prefixes 10.0.1.0/24 --network-security-group $MyNetworkSecurityGroup -o table --only-show-errors
		fi
		# ログインノード作成
		echo "========================== creating login node =========================="
		az vm create \
			--resource-group $MyResourceGroup --location $Location \
			--name ${VMPREFIX}-login \
			--size Standard_D2a_v4 \
			--vnet-name $MyNetwork --subnet $MySubNetwork2 \
			--nsg $MyNetworkSecurityGroup --nsg-rule SSH \
			--public-ip-address-allocation static \
			--image $IMAGE \
			--admin-username $USERNAME --ssh-key-values $SSHKEYFILE \
			--tags "$TAG" -o table --only-show-errors
		# PBSジョブスケジューラノード作成
		echo "========================== creating PBS node ============================"
		az vm create \
			--resource-group $MyResourceGroup --location $Location \
			--name ${VMPREFIX}-pbs \
			--size $PBSVMSIZE \
			--vnet-name $MyNetwork --subnet $MySubNetwork \
			--nsg $MyNetworkSecurityGroup --nsg-rule SSH $ACCELERATEDNETWORKING \
			--public-ip-address-allocation static \
			--image $IMAGE \
			--admin-username $USERNAME --ssh-key-values $SSHKEYFILE \
			--tags "$TAG" -o table --only-show-errors

		# LoginノードIPアドレス取得
		loginvmip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-login --query publicIps -o tsv --only-show-errors)
		echo "$loginvmip" > ./loginvmip
		# PBSノードIPアドレス取得
		pbsvmip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-pbs --query publicIps -o tsv --only-show-errors)
		echo "$pbsvmip" > ./pbsvmip
		# 永続ディスクが必要な場合に設定可能
		if [ $((PBSPERMANENTDISK)) -gt 0 ]; then
			az vm disk attach --new -g $MyResourceGroup --size-gb $PBSPERMANENTDISK --sku Premium_LRS --vm-name ${VMPREFIX}-pbs --name ${VMPREFIX}-pbs-disk0 -o table --only-show-errors || \
				az vm disk attach -g $MyResourceGroup --vm-name ${VMPREFIX}-pbs --name ${VMPREFIX}-pbs-disk0 -o table --only-show-errors
		fi

		# all computenodes: basicsettings - locale, sudo, passwordless, sshd
		basicsettings pbs

		# PBSノード：ディスクフォーマット
		echo "pbsnode: /dev/sdc disk formatting"
		diskformat=$(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "df | grep sdc1")
		echo "diskformat: $diskformat"
		# リモートの /dev/sdc が存在する
		diskformat2=$(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo ls /dev/sdc")
		echo "diskformat2: $diskformat2"
		if [ -n "$diskformat2" ]; then
			# かつ、 /dev/sdc1 が存在しない場合のみ実施
			diskformat3=$(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo ls /dev/sdc1")
			if [[ $diskformat3 != "/dev/sdc1" ]]; then
				# /dev/sdc1が存在しない (not 0)場合のみ実施
				# リモートの /dev/sdc が未フォーマットであるか
				disktype1=$(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo fdisk -l /dev/sdc | grep 'Disk label type'")
				disktype2=$(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo fdisk -l /dev/sdc | grep 'Disk identifier'")
				# どちらも存在しない場合、フォーマット処理
				if [[ -z "$disktype1" ]] || [[ -z "$disktype2" ]] ; then 
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo parted /dev/sdc --script mklabel gpt mkpart xfspart xfs 0% 100%"
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo mkfs.xfs /dev/sdc1"
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo partprobe /dev/sdc1"
					echo "pbsnode: fromatted a new disk."
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "df | grep sdc1"
				fi
			else
				echo "your pbs node has not the device."
			fi
		fi
		unset diskformat && unset diskformat2 && unset diskformat3

		# fstab設定
		echo "pbsnode: setting fstab"
		#pbsvmip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-pbs --query publicIps -o tsv)
		for count in $(seq 1 10); do
			checkssh=$(ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 5' -i "${SSHKEYDIR}" -t $USERNAME@"${pbsvmip}" "uname")
			if [ -n "$checkssh" ]; then
				break
			fi
			echo "waiting sshd @ ${VMPREFIX}-${count}: sleep 10" && sleep 10
		done
		if [ -n "$checkssh" ]; then
			# 重複していないかチェック
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo grep '/dev/sdc1' /etc/fstab" > checkfstabpbs
			checkfstabpbs=$(cat checkfstabpbs | wc -l)
			if [ $((checkfstabpbs)) -ge 2 ]; then 
				echo "pbsnode: deleting dupulicated settings...."
				#ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo sed -i -e '/\/dev/sdc1    \/mnt\/share/d' /etc/fstab"
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo sed -i -e '$ a /dev/sdc1    /mnt/share' /etc/fstab"
			elif [ $((checkfstabpbs)) -eq 1 ]; then
				echo "pbsnode: correct fstab setting"
			elif [ $((checkfstabpbs)) -eq 0 ]; then
				echo "pbsnode: fstab missing - no /dev/sdc1 here!"
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo sed -i -e '$ a /dev/sdc1    /mnt/share' /etc/fstab"
			fi
		else
			# fstab 設定: az vm run-command
			echo "pbsnode: configuring fstab by az vm run-command"
			# 重複していないかチェック
			az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-"${pbsvmip}" --command-id RunShellScript --scripts "sudo grep /dev/sdc1 /etc/fstab" > checkfstabpbs
			checkfstabpbs=$(cat checkfstabpbs | wc -l)
			if [ $((checkfstabpbs)) -ge 2 ]; then 
				echo "pbsnode: deleting dupulicated settings...."
				az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-"${pbsvmip}" --command-id RunShellScript --scripts "sudo sed -i -e '/\/dev/sdc1    \/mnt\/share/d' /etc/fstab"
				az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-"${pbsvmip}" --command-id RunShellScript --scripts "sudo sed -i -e '$ a /dev/sdc1    /mnt/share' /etc/fstab"
			elif [ $((checkfstabpbs)) -eq 1 ]; then
				echo "pbsnode: correct fstab setting"
			elif [ $((checkfstabpbs)) -eq 0 ]; then
				echo "pbsnode: fstab missing: no /mnt/share here!"
				az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-"${pbsvmip}" --command-id RunShellScript --scripts "sudo sed -i -e '$ a /dev/sdc1    /mnt/share' /etc/fstab"
			fi
		fi
		rm ./checkfstabpbs

		# PBSノード：ディレクトリ設定
		echo "pbsnode: data directory setting"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo mkdir -p /mnt/share"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo mount /dev/sdc1 /mnt/share"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo chown $USERNAME:$USERNAME /mnt/share"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "ls -la /mnt"
		# NFS設定
		echo "pbsnode: nfs server settings"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo yum install --quiet -y nfs-utils epel-release"
		# アフターインストール：epel-release
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo yum install --quiet -y md5sum htop"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "echo '/mnt/share *(rw,no_root_squash,async)' | sudo tee /etc/exports"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo systemctl start rpcbind && sudo systemctl start nfs-server"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo systemctl enable rpcbind && sudo systemctl enable nfs-server"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo showmount -e"

		# コンピュートノード：NFSマウント設定
		pbsmountip=$(az vm show -g $MyResourceGroup --name ${VMPREFIX}-pbs -d --query privateIps -otsv)
		echo "pbsnode: mouting new directry on compute nodes: /mnt/share"
		mountdirectory pbs

		# ローカル：OpenPBSバイナリダウンロード
		centosversion=$(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "cat /etc/redhat-release" | cut  -d " " -f 4)
		echo "centosversion: $centosversion"
		# PBSノード：CentOS バージョンチェック。CentOS 7.x か 8.xか判別する
		case $centosversion in
			7.?.* )
				# ローカル：CentOS 7.x openPBSバイナリダウンロード
				baseurl="https://github.com/hirtanak/scripts/releases/download/0.0.1"
				wget -q $baseurl/openpbs-server-20.0.1-0.x86_64.rpm -O ./openpbs-server-20.0.1-0.x86_64.rpm
				md5sum ./openpbs-server-20.0.1-0.x86_64.rpm | cut -d ' ' -f 1 > ./md5server
				md5server=$(cat ./md5server)
				while [ ! "$md5server" = "6e7a7683699e735295dba6e87c6b9fd0" ]; do
					rm ./openpbs-server-20.0.1-0.x86_64.rpm
					wget -q $baseurl/openpbs-server-20.0.1-0.x86_64.rpm -O ./openpbs-server-20.0.1-0.x86_64.rpm
				done
				wget -q $baseurl/openpbs-client-20.0.1-0.x86_64.rpm -O ./openpbs-client-20.0.1-0.x86_64.rpm
				md5sum ./openpbs-client-20.0.1-0.x86_64.rpm | cut -d ' ' -f 1 > ./md5client
				md5client=$(cat ./md5client)
				while [ ! "$md5client" = "7bcaf948e14c9a175da0bd78bdbde9eb" ]; do
					rm ./openpbs-client-20.0.1-0.x86_64.rpm
					wget -q $baseurl/openpbs-client-20.0.1-0.x86_64.rpm -O ./openpbs-client-20.0.1-0.x86_64.rpm
				done
				wget -q $baseurl/openpbs-execution-20.0.1-0.x86_64.rpm -O ./openpbs-execution-20.0.1-0.x86_64.rpm
				md5sum ./openpbs-execution-20.0.1-0.x86_64.rpm | cut -d ' ' -f 1 > ./md5execution
				md5execution=$(cat ./md5execution)
				while [ ! "$md5execution" = "59f5110564c73e4886afd579364a4110" ]; do
					rm ./openpbs-client-20.0.1-0.x86_64.rpm
					wget -q $baseurl/openpbs-client-20.0.1-0.x86_64.rpm -O ./openpbs-client-20.0.1-0.x86_64.rpm
				done
				if [ ! -f ./openpbs-server-20.0.1-0.x86_64.rpm ] || [ ! -f ./openpbs-client-20.0.1-0.x86_64.rpm ] || [ ! -f ./openpbs-execution-20.0.1-0.x86_64.rpm ]; then
					echo "file download error!. please download manually OpenPBS file in current diretory"
					echo "openPBSバイナリダウンロードエラー。githubにアクセスできないネットワーク環境の場合、カレントディレクトリにファイルをダウンロードする方法でも可能"
					exit 1
				fi
			;;
			8.?.* )
				# ローカル：OpenPBSパッケージダウンロード
				wget -q -N https://github.com/openpbs/openpbs/releases/download/v20.0.1/openpbs_20.0.1.centos_8.zip -O ./openpbs_20.0.1.centos_8.zip
				unzip -qq -o ./openpbs_20.0.1.centos_8.zip
				# https://groups.io/g/OpenHPC-users/topic/cannot_install_slurm_due_to/78463158?p=,,,20,0,0,0::recentpostdate%2Fsticky,,,20,2,0,78463158 の問題対応
				wget -q -N http://mirror.centos.org/centos/7/os/x86_64/Packages/hwloc-libs-1.11.8-4.el7.x86_64.rpm -O ./openpbs_20.0.1.centos_8/hwloc-libs-1.11.8-4.el7.x86_64.rpm
			;;
			* )
				echo "skipped PBSノード：openPBSクライアントダウンロード"
			;;
		esac

		# PBSノード：OpenPBSサーババイナリコピー＆インストール
		echo "copy openpbs-server-20.0.1-0.x86_64.rpm"
		case $centosversion in
			7.?.* )
				scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i "${SSHKEYDIR}" ./openpbs-server-20.0.1-0.x86_64.rpm $USERNAME@"${pbsvmip}":/home/$USERNAME/
				# PBSノード：OpenPBSクライアントバイナリコピー＆インストール
				scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i "${SSHKEYDIR}" ./openpbs-client-20.0.1-0.x86_64.rpm $USERNAME@"${pbsvmip}":/home/$USERNAME/
			;;
			8.?.* )
				# PBSノード：OpenPBSクライアントバイナリコピー＆インストール
				scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i "${SSHKEYDIR}" ./openpbs_20.0.1.centos_8/openpbs-client-20.0.1-0.x86_64.rpm $USERNAME@"${pbsvmip}":/home/$USERNAME/
				scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i "${SSHKEYDIR}" ./openpbs_20.0.1.centos_8/openpbs-server-20.0.1-0.x86_64.rpm $USERNAME@"${pbsvmip}":/home/$USERNAME/
				scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i "${SSHKEYDIR}" ./openpbs_20.0.1.centos_8/hwloc-libs-1.11.8-4.el7.x86_64.rpm $USERNAME@"${pbsvmip}":/home/$USERNAME/
			;;
			* )
				echo "skipped PBSノード：openPBSクライアントダウンロード"
			;;
		esac

		case $centosversion in
			7.?.* )
				#  CentOS7.x: PBSノード：OpenPBS Requirement設定
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo yum install --quiet -y expat libedit postgresql-server postgresql-contrib python3 sendmail sudo tcl tk libical"
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo yum install --quiet -y hwloc-libs libICE libSM"
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "ls -la /home/$USERNAME/"
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo yum install --quiet -y /home/$USERNAME/openpbs-server-20.0.1-0.x86_64.rpm"

				# openPBSをビルドする場合：現在は利用していない
				# ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "wget -q https://github.com/openpbs/openpbs/archive/refs/tags/v20.0.1.tar.gz -O /home/$USERNAME/openpbs-20.0.1.tar.gz"
				# ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "tar zxvf /home/$USERNAME/openpbs-20.0.1.tar.gz"
				# ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "LANG=C /home/$USERNAME/openpbs-20.0.1/autogen.sh"
				# ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "LANG=C /home/$USERNAME/openpbs-20.0.1/configure --prefix=/opt/pbs"
				# ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "make"
				# ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${pbsvmip} -t -t "sudo make install"
				# ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo yum install --quiet -y /home/$USERNAME/openpbs-client-20.0.1-0.x86_64.rpm"
			;;
			8.?.* )
				# CentOS8.x: PBSノード：OpenPBS Requirement設定
				echo "installing prerequisite for CentOS8.x...."
				#ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo dnf install -y dnf-plugins-core"
				#ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo dnf config-manager --set-enabled powertools"
				# ライブラリエラーのため、1.11.8である必要がある
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo dnf install --quiet -y hwloc-libs-1.11.8-4.el7.x86_64.rpm"
				# hwloc-devel, libedit-devel
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo dnf install --quiet -y gcc make rpm-build libtool libX11-devel libXt-devel libical-devel ncurses-devel perl postgresql-devel postgresql-contrib python3-devel tcl-devel tk-devel swig expat-devel openssl-devel libXext libXft autoconf automake gcc-c++"

				echo "installing OpenPBS package"
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo yum install --quiet -y /home/$USERNAME/openpbs-server-20.0.1-0.x86_64.rpm"
			;;
			* )
				echo "skipped コンピュートノード：openPBSクライアントインストール"
			;;
		esac

		# PBSコンフィグファイル設定
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo /opt/pbs/libexec/install_db"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo /opt/pbs/libexec/pbs_habitat"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo /opt/pbs/libexec/pbs_postinstall"
		# PBSノード：configure /etc/pbs.conf file
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo sed -i -e 's/PBS_START_SERVER=0/PBS_START_SERVER=1/g' /etc/pbs.conf"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo sed -i -e 's/PBS_START_SCHED=0/PBS_START_SCHED=1/g' /etc/pbs.conf"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo sed -i -e 's/PBS_START_COMM=0/PBS_START_COMM=1/g' /etc/pbs.conf"
		# PBSノード：openPBSパーミッション設定
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo chmod 4755 /opt/pbs/sbin/pbs_iff"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo chmod 4755 /opt/pbs/sbin/pbs_rcp"

		# ホストファイル作成準備：既存ファイル削除
		# ホストファイル作成
		gethostsfile
		#,PublicIp:network.publicIpAddresses[0].ipAddress}
		# 自然な順番でソートする
		# vmlist 取り出し：1列目
		# nodelist 取り出し：2列目
		# ダブルクォーテーション削除: sed -i -e "s/\"//g" ./tmphostsfile
		# ファイルの重複行削除。列は2列まで想定: cat  ./tmphostsfile | awk '!colname[$1]++{print $1, "\t" ,$2}' > ./hostsfile
#		getipaddresslist vmlist ipaddresslist nodelist
		# PBSノード追加
		#echo "${VMPREFIX}-pbs" >> vmlist
		# pbsmountip がPBSノードの内部IPアドレス
		#echo ${pbsmountip} >> nodelist
		# PASTEコマンドでホストファイル作成
#		paste ./nodelist ./vmlist > ./hostsfile
#		echo "show current hostsfile"
#		cat ./hostsfile
		# テンポラリファイル削除
		#rm ./tmphostsfile
		#rm ./tmphostsfile2

		# PBSノード：ホストファイルコピー
		echo "pbsnodes: copy hostsfile to all compute nodes"
		scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./hostsfile $USERNAME@"${pbsvmip}":/home/$USERNAME/
		# /etc/hosts.original の確認
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "file /etc/hosts.original" > hostsoriginal
		if [ -z "$hostsoriginal" ]; then
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo cp /etc/hosts /etc/hosts.original"
		fi
		rm hostsoriginal
		# ホストファイルの追加（重複チェック）
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "cat /home/$USERNAME/hostsfile | sudo tee -a /etc/hosts"
		if [ -f ./duplines.sh ]; then rm ./duplines; fi
cat <<'EOL' >> duplines.sh
#!/bin/bash 
lines=$(sudo cat /etc/hosts | wc -l)
MAXVM=
USERNAME=
if [ $((lines)) -ge $((MAXVM+2)) ]; then
    sudo awk '!colname[$2]++{print $1, "\t" ,$2}' /etc/hosts > /home/$USERNAME/hosts2
	if [ -s /home/$USERNAME/hosts2 ]; then
		echo "-s: copy hosts2 to host...."
		sudo cp /home/$USERNAME/hosts2 /etc/hosts
	fi
	if [ ! -f /home/$USERNAME/hosts2 ]; then
		echo "!-f: copy hosts2 to host...."
		sudo sort -V -k 2 /etc/hosts | uniq > /etc/hosts2
		sudo cp /home/$USERNAME/hosts2 /etc/hosts
	fi
else
	echo "skip"
fi
EOL
		# マックスVMのまま残す（置換するため）
		sed -i -e "s/MAXVM=/MAXVM=${MAXVM}/" duplines.sh
		sed -i -e "s/USERNAME=/USERNAME=${USERNAME}/" duplines.sh
		scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./duplines.sh $USERNAME@"${pbsvmip}":/home/$USERNAME/
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo bash /home/$USERNAME/duplines.sh"
		echo "pbsnodes: /etc/hosts"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo cat /etc/hosts | grep ${VMPREFIX}"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "rm -rf /home/$USERNAME/hosts2"

		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "ln -s /mnt/share/ /home/$USERNAME/"

### ===========================================================================
		# openPBSクライアントコピー
		# CentOS 7.x か 8.xか判別する
		case $centosversion in
			7.?.* )
				echo "CentOS7.x: copy openpbs-execution-20.0.1-0.x86_64.rpm to all compute nodes"
				parallel -a ipaddresslist "scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 360' -i ${SSHKEYDIR} ./openpbs-execution-20.0.1-0.x86_64.rpm $USERNAME@{}:/home/$USERNAME/"
				# ダウンロード、およびMD5チェック
				count=0
				if [ -f ./md5executionremote ]; then rm ./md5executionremote; fi
				if [ -f ./md5executionremote2 ]; then rm ./md5executionremote2; fi
				for count in $(seq 1 $MAXVM); do
					line=$(sed -n "${count}"P ./ipaddresslist)
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "md5sum /home/$USERNAME/openpbs-execution-20.0.1-0.x86_64.rpm | cut -d ' ' -f 1" > md5executionremote
					md5executionremote=$(cat ./md5executionremote)
					echo "md5executionremote: $md5executionremote"
					for cnt in $(seq 1 3); do
						echo "checking md5...: $cnt"
						if [ "$md5executionremote" == "$md5execution" ]; then
						# 固定ではうまくいかない
						# if [ "$md5executionremote" != "59f5110564c73e4886afd579364a4110" ]; then
							ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "rm /home/$USERNAME/openpbs-execution-20.0.1-0.x86_64.rpm"
							scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./openpbs-execution-20.0.1-0.x86_64.rpm $USERNAME@"${line}":/home/$USERNAME/openpbs-execution-20.0.1-0.x86_64.rpm
							ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "md5sum /home/$USERNAME/openpbs-execution-20.0.1-0.x86_64.rpm | cut -d ' ' -f 1" > md5executionremote
							md5executionremote=$(cat ./md5executionremote)
							echo "md5executionremote: $md5executionremote"
							echo "md5executionremote2: $md5executionremote2"
							for cnt2 in $(seq 1 3); do
								echo "checking md5...: $cnt2"
								if [ "$md5executionremote2" != "$md5execution" ]; then
								# 固定ではうまくいかない
								# if [ "$md5executionremote2" != "59f5110564c73e4886afd579364a4110" ]; then
									ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "rm /tmp/openpbs-execution-20.0.1-0.x86_64.rpm"
									ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "wget -q $baseurl/openpbs-execution-20.0.1-0.x86_64.rpm -O /tmp/openpbs-execution-20.0.1-0.x86_64.rpm"
									ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "md5sum /tmp/openpbs-execution-20.0.1-0.x86_64.rpm  | cut -d ' ' -f 1" > md5executionremote2
									md5executionremote2=$(cat ./md5executionremote2)
									ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "cp /tmp/openpbs-execution-20.0.1-0.x86_64.rpm /home/$USERNAME/openpbs-execution-20.0.1-0.x86_64.rpm"
									echo "md5executionremote2: $md5executionremote2"
								else
									echo "match md5 by md5executionremote2"
									md5executionremote2=$(cat ./md5executionremote2)
									break
								fi
							done
						else
							echo "match md5 by md5executionremote"
							md5executionremote=$(cat ./md5executionremote)
							break
						fi
					done
				done
				if [ -f ./md5executionremote ]; then rm ./md5executionremote; fi
				if [ -f ./md5executionremote2 ]; then rm ./md5executionremote2; fi
			;;
			8.?.* )
				echo "CentOS8.x: copy openpbs-execution-20.0.1-0.x86_64.rpm to all compute nodes"
				# ライブラリ対応 
				parallel -a ipaddresslist "scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 360' -i ${SSHKEYDIR} ./openpbs_20.0.1.centos_8/hwloc-libs-1.11.8-4.el7.x86_64.rpm $USERNAME@{}:/home/$USERNAME/"
				parallel -a ipaddresslist "scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 360' -i ${SSHKEYDIR} ./openpbs_20.0.1.centos_8/openpbs-execution-20.0.1-0.x86_64.rpm $USERNAME@{}:/home/$USERNAME/"
			;;
		esac

		# OpenPBSクライアント：インストール準備
		case $centosversion in
			7.?.* )
				echo "CentOS7.x: confuguring all compute nodes"
				parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30'-i ${SSHKEYDIR} $USERNAME@{} -t -t 'sudo yum install --quiet -y hwloc-libs libICE libSM'"
				parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t 'sudo yum install --quiet -y libnl3'"
			;;
			8.?.* )
				echo "CentOS 8.x: confuguring all compute nodes requisites"
				parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@{} -t -t 'sudo dnf install --quiet -y hwloc-libs-1.11.8-4.el7.x86_64.rpm'"
				parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@{} -t -t 'sudo dnf install --quiet -y libICE libSM'"
				parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t 'sudo dnf install --quiet -y libnl3'"

			;;
		esac

		# OpenPBSクライアント：インストール openpbs-execution-20.0.1-0.x86_64.rpm
		echo "CentOS 7.x and 8.x: installing openpbs-execution-20.0.1-0.x86_64.rpm"
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo yum install --quiet -y /home/$USERNAME/openpbs-execution-20.0.1-0.x86_64.rpm""
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo rpm -aq | grep openpbs""

		# OpenPBS 設定
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo /opt/pbs/libexec/pbs_habitat""
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo /opt/pbs/libexec/pbs_postinstall""
		# pbs.confファイル生成
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo sed -i -e 's/PBS_START_MOM=0/PBS_START_MOM=1/g' /etc/pbs.conf""
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo sed -i -e s/CHANGE_THIS_TO_PBS_SERVER_HOSTNAME/${VMPREFIX}-pbs/g /etc/pbs.conf""
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo cat /etc/pbs.conf""
		# OpenPBSクライアント：パーミッション設定
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo chmod 4755 /opt/pbs/sbin/pbs_iff""
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo chmod 4755 /opt/pbs/sbin/pbs_rcp""
		# OpenPBSクライアント：/var/spool/pbs/mom_priv/config コンフィグ設定
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo sed -i -e s/CHANGE_THIS_TO_PBS_SERVER_HOSTNAME/${VMPREFIX}-pbs/g /var/spool/pbs/mom_priv/config""
		for count in $(seq 1 $MAXVM); do
			line=$(sed -n "${count}"P ./ipaddresslist)
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "sudo sed -i -e s/CHANGE_THIS_TO_PBS_SERVER_HOSTNAME/${VMPREFIX}-pbs/g /var/spool/pbs/mom_priv/config"
		done
		# OpenPBSクライアント：HOSTSファイルコピー・設定（全体）
		parallel -a ipaddresslist "scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} ./hostsfile $USERNAME@{}:/home/$USERNAME/"
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t "cat /home/$USERNAME/hostsfile | sudo tee -a /etc/hosts""
		# OpenPBSクライアント：HOSTSファイルコピー・設定（個別）・重複排除
		for count in $(seq 1 $MAXVM); do
			line=$(sed -n "${count}"P ./ipaddresslist)
			# /etc/hosts.original の確認
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "file /etc/hosts.original" > hostsoriginal
			if [ -z "$hostsoriginal" ]; then
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "sudo cp /etc/hosts /etc/hosts.original"
			fi
			rm hostsoriginal
			# ホストファイルの重複排除
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "cat /home/$USERNAME/hostsfile | sudo tee -a /etc/hosts"
			if [ ! -f ./duplines.sh ]; then 
				echo "error!: duplines.sh was deleted. please retry addlogin command."
			fi
				sed -i -e "s/MAXVM=/MAXVM=${MAXVM}/" duplines.sh
				sed -i -e "s/USERNAME=/USERNAME=${USERNAME}/" duplines.sh
			scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./duplines.sh $USERNAME@"${line}":/home/$USERNAME/
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "sudo bash /home/$USERNAME/duplines.sh"
			echo "${VMPREFIX}-${count}: show /etc/hosts"
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "sudo cat /etc/hosts | grep ${VMPREFIX}"
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "sudo rm -rf /home/$USERNAME/hosts2"
		done
### ===========================================================================
		# PBSプロセス起動
		# PBSノード起動＆$USERNAME環境変数設定
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "grep pbs.sh /home/azureuser/.bashrc" > ./pbssh
		pbssh=$(cat ./pbssh)
		if [ -z "$pbssh" ]; then
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "yes | sudo /etc/init.d/pbs start"
		fi
		# OpenPBSクライアントノード起動＆$USERNAME環境変数設定
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo /etc/init.d/pbs start""
		vm1ip=$(head -n 1 ./ipaddresslist)
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "grep pbs.sh /home/azureuser/.bashrc" > ./pbssh
		pbssh=$(cat ./pbssh)
		if [ -z "$pbssh" ]; then
			parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t 'echo 'source /etc/profile.d/pbs.sh' >> /home/$USERNAME/.bashrc'"
		fi
		rm ./pbssh
		echo "finished to set up additonal login and PBS node"
### ===========================================================================
		# PBSジョブスケジューラセッティング
		echo "configpuring PBS settings"
		if [ -f ./setuppbs.sh ]; then rm ./setuppbs.sh; fi
		for count in $(seq 1 $MAXVM); do
			echo "/opt/pbs/bin/qmgr -c "create node ${VMPREFIX}-${count}"" >> setuppbs.sh
		done
		# ジョブ履歴有効化
		echo "/opt/pbs/bin/qmgr -c s s job_history_enable = 1" >> setuppbs.sh
		# シングルクォーテーション処理
		sed -i -e "s/-c /-c '/g" setuppbs.sh || sudo sed -i -e "s/-c /-c '/g" setuppbs.sh
		sed -i -e "s/$/\'/g" setuppbs.sh || sudo sed -i -e "s/$/\'/g" setuppbs.sh
		echo "setuppbs.sh: $(cat ./setuppbs.sh)"
		scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./setuppbs.sh $USERNAME@"${pbsvmip}":/home/$USERNAME/setuppbs.sh
		# SSH鍵登録
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t 'sudo cp /root/.ssh/authorized_keys /root/.ssh/authorized_keys.old'
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo cp /home/$USERNAME/.ssh/authorized_keys /root/.ssh/authorized_keys"
		# ジョブスケジューラセッティング
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" root@"${pbsvmip}" -t -t "bash /home/$USERNAME/setuppbs.sh"
		rm ./setuppbs.sh
### ===========================================================================
		# 追加機能：PBSノードにnodelistを転送する
		scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./nodelist $USERNAME@"${pbsvmip}":/home/$USERNAME/
		# PBSノードからマウンド状態をチェックするスクリプト生成
		if [ -f ./checknfs.sh ]; then rm checknfs.sh; fi
		cat <<'EOL' >> checknfs.sh
#!/bin/bash

#VMPREFIX=sample
#MAXVM=4

USERNAME=$(whoami)
echo $USERNAME
SSHKEY=$(echo ${VMPREFIX})
echo $SSHKEY
# 文字列"-pbs" は削除
SSHKEYDIR="$HOME/.ssh/${SSHKEY%-pbs}"
chmod 600 $SSHKEYDIR
echo $SSHKEYDIR
vm1ip=$(cat /home/$USERNAME/nodelist | head -n 1)
echo $vm1ip

# 必要なパッケージ。Ubuntuの場合、以下のパッケージが必要
if   [ -e /etc/debian_version ] || [ -e /etc/debian_release ]; then
    # Check Ubuntu or Debian
    if [ -e /etc/lsb-release ]; then
        # Ubuntu
        echo "ubuntu"
		sudo apt install -qq -y parallel jq curl || apt install -qq -y parallel jq curl
    else
        # Debian
        echo "debian"
		sudo apt install -qq -y parallel jq curl || apt install -qq -y parallel jq curl
	fi
elif [ -e /etc/fedora-release ]; then
    # Fedra
    echo "fedora"
elif [ -e /etc/redhat-release ]; then
	echo "Redhat or CentOS"
	sudo yum install --quiet -y parallel jq curl || yum install -y parallel jq curl
fi

ssh -i $SSHKEYDIR $USERNAME@${vm1ip} -t -t 'sudo showmount -e'
parallel -v -a ./ipaddresslist "ssh -i $SSHKEYDIR $USERNAME@{} -t -t 'df -h | grep 10.0.0.'"
echo "====================================================================================="
parallel -v -a ./ipaddresslist "ssh -i $SSHKEYDIR $USERNAME@{} -t -t 'sudo cat /etc/fstab'"
EOL
		VMPREFIX=$(grep "VMPREFIX=" "${CMDNAME}" | head -n 1 | cut -d "=" -f 2)
		sed -i -e "s/^#VMPREFIX=sample/VMPREFIX=$VMPREFIX/" ./checknfs.sh
		MAXVM=$(grep "MAXVM=" "${CMDNAME}" | head -n 1 | cut -d "=" -f 2)
		sed -i -e "s/^#MAXVM=4/MAXVM=$MAXVM/" ./checknfs.sh
		# 最後に転送実施
		scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./checknfs.sh $USERNAME@"${pbsvmip}":/home/$USERNAME/
		# PBSノードでの実施なので ipaddresslist(外部IP) から nodelist(内部IP) に変更
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sed -i -e "s!./ipaddresslist!./nodelist!" /home/$USERNAME/checknfs.sh"
	;;
#### ==========================================================================
#### ==========================================================================
	start )
		# 引数 1 あったら終了
	    if [ $# -gt 1 ]; then echo "error!. you can use no parameter(s) here ."; exit 1; fi

		## PBSノード：OSディスクタイプ変更: Premium_LRS
		azure_sku2="Premium_LRS"
		# PBSノードの存在チェック
		osdiskidpbs=$(az vm show -g $MyResourceGroup --name "${VMPREFIX}"-pbs --query storageProfile.osDisk.managedDisk.id -o tsv --only-show-errors)
		if [ -n "$osdiskidpbs" ]; then
			az disk update --sku ${azure_sku2} --ids "${osdiskidpbs}" -o table --only-show-errors
			echo "starting PBS VM"
			az vm start -g $MyResourceGroup --name "${VMPREFIX}"-pbs -o none &
			# PBSノードが存在すればログインノードも存在する
			echo "starting loging VM"
			az vm start -g $MyResourceGroup --name "${VMPREFIX}"-login -o none &
		else
			# PBSノードのOSディスクが存在しなければPBSノードも存在しない
			echo "no PBS node here!"
		fi

		# VM1-N: OSディスクタイプ変更: Premium_LRS
		azure_sku2="Premium_LRS"
		if [ ! -f ./tmposdiskidlist ]; then rm ./tmposdiskidlist; fi
		for count in $(seq 1 "$MAXVM") ; do
			disktmp=$(az vm show -g $MyResourceGroup --name "${VMPREFIX}"-"${count}" --query storageProfile.osDisk.managedDisk.id -o tsv --only-show-errors)
			echo "$disktmp" >> tmposdiskidlist
		done
		echo "converting computing node OS disk"
		parallel -a ./tmposdiskidlist "az disk update --sku ${azure_sku2} --ids {} -o none &"
		sleep 10
		echo "starting VM ${VMPREFIX}-1"
		az vm start -g $MyResourceGroup --name "${VMPREFIX}"-1 -o none &
		echo "starting VM ${VMPREFIX}:2-$MAXVM compute nodes"
		seq 2 "$MAXVM" | parallel "az vm start -g $MyResourceGroup --name ${VMPREFIX}-{} -o none &"
		echo "checking $MAXVM compute VM's status"
		numvm=0
		tmpnumvm="default"
		while [ -n "$tmpnumvm" ]; do
			tmpnumvm=$(az vm list -d -g $MyResourceGroup --query "[?powerState=='VM starting']" -o tsv --only-show-errors)
			echo "$tmpnumvm" | tr ' ' '\n' > ./tmpnumvm.txt
			numvm=$(grep -c "starting" ./tmpnumvm.txt)
			echo "current starting VMs: $numvm. All VMs are already running!"
			sleep 5
		done
		rm ./tmpnumvm.txt
		sleep 30

		# ダイナミックの場合（デフォルト）、再度IPアドレスリストを作成しなおす
		if [ ! -f ./ipaddresslist ]; then rm ./ipaddresslist; fi
		echo "creating ipaddresslist"
		getipaddresslist vmlist ipaddresslist
		echo "show new ipaddresslist"
		cat ./ipaddresslist

		# check ssh connectivity
		checksshconnection all
		connection=$(cat ./checksshtmp | wc -l)
		if [ $((connection)) -eq $((MAXVM)) ]; then 
			echo "all node ssh avaiable"
		else
			echo "some of nodes are not ssh avaiable"
		fi
		rm ./checksshtmp

		# VM1 $2 マウント
		echo "vm1: nfs server @ ${VMPREFIX}-1"
		mountdirectory vm1

		echo "end of starting up computing nodes"
		# PBSノードがなければ終了
		if [ -z "$osdiskidpbs" ]; then
			echo "no PBS node here!"
			exit 0
		fi
		# PBSノード：マウント設定
		echo "pbsnode: nfs server @ ${VMPREFIX}-pbs"
		mountdirectory pbs
		echo "end of start command"
	;;
	startvm )
		# 引数 2 っあたら終了
	    if [ $# -gt 2 ]; then echo "error!. you can use no parameter(s) here ."; exit 1; fi

		# VM1-N: OSディスクタイプ変更: Premium_LRS
		azure_sku2="Premium_LRS"
		disktmp=$(az vm show -g $MyResourceGroup --name "${VMPREFIX}"-"${2}" --query storageProfile.osDisk.managedDisk.id -o tsv --only-show-errors)
		echo "converting computing node OS disk"
		az disk update --sku ${azure_sku2} --ids "${disktmp}" -o none
		echo "starting VM ${VMPREFIX}-1"
		az vm start -g $MyResourceGroup --name "${VMPREFIX}"-1 -o none
		echo "starting VM ${VMPREFIX}:2-$MAXVM compute nodes"
		az vm start -g $MyResourceGroup --name ${VMPREFIX}-"${2}" -o none
		echo "checking $MAXVM compute VM's status"
		sleep 30

		# ダイナミックの場合（デフォルト）、再度IPアドレスリストを作成しなおす
		if [ ! -f ./ipaddresslist ]; then rm ./ipaddresslist; fi
		echo "creating ipaddresslist"
		getipaddresslist vmlist ipaddresslist
		echo "show new vm ip"
		sed -n "${2}"P ./ipaddresslist

		# VM1 $2 マウント
		echo "${VMPREFIX}-${2}: mounting vm1 nfs server...."
		mountdirectory vm1

		# PBSノードがなければ終了：PBSノードの存在チェック
		osdiskidpbs=$(az vm show -g $MyResourceGroup --name "${VMPREFIX}"-pbs --query storageProfile.osDisk.managedDisk.id -o tsv --only-show-errors)
		if [ -z "$osdiskidpbs" ]; then
			echo "no PBS node here!"
			exit 0
		fi
		# PBSノード：マウント設定
		echo "${VMPREFIX}-${2}: mounting nfs server...."
		mountdirectory pbs
		echo "end of start command"
	;;
	startvms )
		# 引数 3 あったら終了
	    if [ $# -gt 3 ]; then echo "error!. you can use no parameter(s) here ."; exit 1; fi
		# 引数 1のみあったら終了
	    if [ $# -eq 1 ]; then echo "error!. you need TWO parameter2 here ."; exit 1; fi
		echo "コマンドシンタクス:VM#2,3,4を起動する場合 ./$CMDNAME startvms 2 4"

		# VM1-N: OSディスクタイプ変更: Premium_LRS
		azure_sku2="Premium_LRS"
		for count in $(seq "$2" "$3") ; do
			echo "upating disk Premium_LRS in VM ${VMPREFIX}-${count}"
			disktmp=$(az vm show -g $MyResourceGroup --name "${VMPREFIX}"-"${count}" --query storageProfile.osDisk.managedDisk.id -o tsv --only-show-errors)
			echo "converting computing node OS disk"
			az disk update --sku ${azure_sku2} --ids "${disktmp}" -o none
			echo "starting VM $count"
			az vm start -g $MyResourceGroup --name "${VMPREFIX}"-"${count}" -o none &
		done

		# 停止：VMがすべて起動するまで待ち
		for count in $(seq "$2" "$3"); do
			while [ "$vmstate" != "VM running"  ]; do
				vmstate=$(az vm get-instance-view -g $MyResourceGroup --name "${VMPREFIX}"-"${count}" --query {PowerState:instanceView.statuses[1].displayStatus} -o tsv --only-show-errors)
				echo "wating for VM: ${VMPREFIX}-${count} was running"
				sleep 10
			done
		done
	
		# ダイナミックの場合（デフォルト）、再度IPアドレスリストを作成しなおす
		if [ ! -f ./ipaddresslist ]; then rm ./ipaddresslist; fi
		echo "creating ipaddresslist"
		getipaddresslist vmlist ipaddresslist
		echo "show new vm ip"
		sed -n "${2}"P ./ipaddresslist

		# VM1 $2 マウント
		echo "${VMPREFIX}-${2}: mounting vm1 nfs server...."
		mountdirectory vm1

		# PBSノードがなければ終了：PBSノードの存在チェック
		osdiskidpbs=$(az vm show -g $MyResourceGroup --name "${VMPREFIX}"-pbs --query storageProfile.osDisk.managedDisk.id -o tsv --only-show-errors)
		if [ -z "$osdiskidpbs" ]; then
			echo "no PBS node here!"
			exit 0
		fi
		# PBSノード：マウント設定
		echo "${VMPREFIX}-${2}: mounting nfs server...."
		mountdirectory pbs
		echo "end of start command"
	;;
	stop )
		# すべてのコンピュートノード停止
		# 引数があったら終了
	    if [ $# -gt 1 ]; then echo "error!. you can use no parameter(s) here ."; exit 1; fi

		for count in $(seq 1 "$MAXVM") ; do
			if [ -f ./tmposdiskidlist ]; then rm ./tmposdiskidlist; fi
			#for count in $(seq "$2" "$3") ; do
			echo "getting disk id..."
			disktmp=$(az vm show -g $MyResourceGroup --name "${VMPREFIX}"-"${count}" --query storageProfile.osDisk.managedDisk.id -o tsv --only-show-errors)
			echo "$disktmp" >> tmposdiskidlist
			#done
			echo "stoping VM $count"
				az vm deallocate -g $MyResourceGroup --name "${VMPREFIX}"-"${count}" &
		done

		# 停止：全コンピュートVMが停止まで待つ
		for count in $(seq 1 "$MAXVM"); do
			while [ "$vmstate" != "VM deallocated"  ]; do
			vmstate=$(az vm get-instance-view -g $MyResourceGroup --name "${VMPREFIX}"-"${count}" --query {PowerState:instanceView.statuses[1].displayStatus} -o tsv --only-show-errors)
			echo "wating for VM: ${VMPREFIX}-${count} was stooped"
			sleep 10
			done
		done

		# OSディスクタイプ変更: Standard_LRS
		azure_sku1="Standard_LRS"
		echo "converting computing node OS disk"
		parallel -v -a ./tmposdiskidlist "az disk update --sku ${azure_sku1} --ids {} -o none" 
	;;
	stop-all )
		# 引数があったら終了
	    if [ $# -gt 1 ]; then echo "error!. you can use only 1 parameter here ."; exit 1; fi

		if [ -f ./tmposdiskidlist ]; then rm ./tmposdiskidlist; fi
		for count in $(seq 1 "$MAXVM") ; do
			disktmp=$(az vm show -g $MyResourceGroup --name "${VMPREFIX}"-"${count}" --query storageProfile.osDisk.managedDisk.id -o tsv --only-show-errors)
			echo "$disktmp" >> tmposdiskidlist
		done
		for count in $(seq 1 "$MAXVM") ; do
			echo "stoping VM $count"
			az vm deallocate -g $MyResourceGroup --name "${VMPREFIX}"-"${count}" &
		done
		echo "stoping PBS VM"
		az vm deallocate -g $MyResourceGroup --name "${VMPREFIX}"-pbs -o none &
		echo "stoping login VM"
		az vm deallocate -g $MyResourceGroup --name "${VMPREFIX}"-login -o none &

		# 停止：全コンピュートVMが停止まで待つ
		for count in $(seq "$2" "$3"); do
			while [ "$vmstate" != "VM deallocated"  ]; do
			vmstate=$(az vm get-instance-view -g $MyResourceGroup --name "${VMPREFIX}"-"${count}" --query {PowerState:instanceView.statuses[1].displayStatus} -o tsv --only-show-errors)
			echo "wating for VM: ${VMPREFIX}-${count} was stooped"
			sleep 10
			done
		done

		# OSディスクタイプ変更: Standard_LRS
		azure_sku1="Standard_LRS"
		echo "converting computing node OS disk"
		parallel -v -a ./tmposdiskidlist "az disk update --sku ${azure_sku1} --ids {} -o none"
		# Dataディスクタイプ変更: Standard_LRS
		echo "converting PBS node data disk"
		az vm show -g $MyResourceGroup --name "${VMPREFIX}"-pbs --query storageProfile.dataDisks[*].managedDisk -o tsv | awk -F" " '{print $2}' | xargs -I{} az disk update --sku ${azure_sku1} --ids {} -o none
		echo "converting compute node #1 data disk"
		az vm show -g $MyResourceGroup --name "${VMPREFIX}"-1 --query storageProfile.dataDisks[*].managedDisk -o tsv | awk -F" " '{print $2}' | xargs -I{} az disk update --sku ${azure_sku1} --ids {} -o none
	;;
	stopvm )
		# 引数 2あったら終了
	    if [ $# -gt 2 ]; then echo "error!. you can use only 1 parameter here ."; exit 1; fi
		echo "コマンドシンタクス:VM#2を停止する場合 ./$CMDNAME stopvm 2"
		
		echo "stoping VM $2"
		az vm deallocate -g $MyResourceGroup --name "${VMPREFIX}"-"$2" --only-show-errors

		# OSディスクタイプ変更: Standard_LRS
		echo "converting PBS node data disk"
		azure_sku1="Standard_LRS"
		az vm show -g $MyResourceGroup --name "${VMPREFIX}"-${2} --query storageProfile.dataDisks[*].managedDisk -o tsv | awk -F" " '{print $2}' | xargs -I{} az disk update --sku ${azure_sku1} --ids {} -o none

	;;
	stopvms )
		# 引数 3 あったら終了
	    if [ $# -gt 3 ]; then echo "error!. you can use over 3 parameters here ."; exit 1; fi
		# 引数 1 のみなら終了
	    if [ $# -eq 1 ]; then echo "error!. you need one more parameter here ."; exit 1; fi
		echo "コマンドシンタクス:VM#2,3,4を停止する場合 ./$CMDNAME stopvm 2 4"

		echo "getting disk id..."
		if [ -f ./tmposdiskidlist ]; then rm ./tmposdiskidlist; fi
		for count in $(seq "$2" "$3") ; do
			disktmp=$(az vm show -g $MyResourceGroup --name "${VMPREFIX}"-"${count}" --query storageProfile.osDisk.managedDisk.id -o tsv --only-show-errors)
			echo "$disktmp" >> tmposdiskidlist
		done

		echo "stoping VM $2 $3"
		for count in $(seq "$2" "$3") ; do
			echo "stoping VM $count"
			az vm deallocate -g $MyResourceGroup --name "${VMPREFIX}"-"${count}" -o none &
		done

		# 停止：全コンピュートVMが停止まで待つ
		for count in $(seq "$2" "$3"); do
			while [ "$vmstate" != "VM deallocated"  ]; do
			vmstate=$(az vm get-instance-view -g $MyResourceGroup --name "${VMPREFIX}"-"${count}" --query {PowerState:instanceView.statuses[1].displayStatus} -o tsv --only-show-errors)
			echo "wating for VM: ${VMPREFIX}-${count} was stooped"
			sleep 10
			done
		done

		# OSディスクタイプ変更: Standard_LRS
		azure_sku1="Standard_LRS"
		echo "converting computing node OS disk"
		parallel -v -a ./tmposdiskidlist "az disk update --sku ${azure_sku1} --ids {} -o none"
	;;
	list )
		# 引数があったら終了
	    if [ $# -gt 1 ]; then echo "error!. you can use no parameter(s) here ."; exit 1; fi

		echo "listng running/stopped VM"
		az vm list -g $MyResourceGroup -d -o table --only-show-errors

		echo "prep..."
		getipaddresslist vmlist ipaddresslist
		echo "nfs server vm status"
		# vm1state=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-1 --query powerState)
		vm1ip=$(az vm show -d -g $MyResourceGroup --name "${VMPREFIX}"-1 --query publicIps -o tsv --only-show-errors)
		pbsvmip=$(az vm show -d -g $MyResourceGroup --name "${VMPREFIX}"-pbs --query publicIps -o tsv --only-show-errors)
		# PBSノードのパブリックIPアドレスの判定
		if [ -z "$pbsvmip" ]; then
			echo "no PBS node here! checking only compute nodes."
			# コンピュートノードのみのチェック
			count=0
			checkssh=$(ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i "${SSHKEYDIR}" -t $USERNAME@"${vm1ip}" "uname")
			if [ -n "$checkssh" ]; then
				echo "${VMPREFIX}-1: nfs server status"
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" 'sudo showmount -e'
				echo "nfs client mount status"
					for count in $(seq 2 "$MAXVM"); do
						line=$(sed -n "${count}"P ./ipaddresslist)
						ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" -t -t $USERNAME@"${line}" "echo '########## host: ${VMPREFIX}-${count} ##########'"
						ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" -t -t $USERNAME@"${line}" "df | grep '/mnt/'"
					done
				else
					# SSHできないのでaz vm run-commandでの情報取得
					echo "az vm run-command: nfs server status"
					az vm run-command invoke -g $MyResourceGroup --name "${VMPREFIX}"-1 --command-id RunShellScript --scripts "sudo showmount -e"
					echo "nfs client mount status:=======1-2 others: skiped======="
					az vm run-command invoke -g $MyResourceGroup --name "${VMPREFIX}"-1 --command-id RunShellScript --scripts "df | grep /mnt/"
					az vm run-command invoke -g $MyResourceGroup --name "${VMPREFIX}"-2 --command-id RunShellScript --scripts "df | grep /mnt/"
			fi
			# コンピュートノードVM#1のマウントだけ完了し、コマンド完了
			echo "end of list command"
			exit 0
		fi
		# PBSノード、コンピュートノードのNFSマウント確認
		count=0
		checkssh=$(ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i "${SSHKEYDIR}" -t $USERNAME@"${vm1ip}" "uname")
		checkssh2=$(ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i "${SSHKEYDIR}" -t $USERNAME@"${pbsvmip}" "uname")
		if [ -n "$checkssh" ] && [ -n "$checkssh2" ]; then
			echo "${VMPREFIX}-pbs: nfs server status"
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" 'sudo showmount -e'
			echo "${VMPREFIX}-1: nfs server status"
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" 'sudo showmount -e'
			echo "nfs client mount status"
			for count in $(seq 2 "$MAXVM"); do
				line=$(sed -n "${count}"P ./ipaddresslist)
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" -t -t $USERNAME@"${line}" "echo '########## host: ${VMPREFIX}-${count} ##########'"
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" -t -t $USERNAME@"${line}" "df | grep '/mnt/'"
			done
		else
			echo "az vm run-command: nfs server status"
			az vm run-command invoke -g $MyResourceGroup --name "${VMPREFIX}"-pbs --command-id RunShellScript --scripts "sudo showmount -e"
			az vm run-command invoke -g $MyResourceGroup --name "${VMPREFIX}"-1 --command-id RunShellScript --scripts "sudo showmount -e"
			echo "nfs client mount status:=======VM 1-2'status. other VMs are skiped======="
			az vm run-command invoke -g $MyResourceGroup --name "${VMPREFIX}"-1 --command-id RunShellScript --scripts "df | grep /mnt/"
			az vm run-command invoke -g $MyResourceGroup --name "${VMPREFIX}"-2 --command-id RunShellScript --scripts "df | grep /mnt/"
		fi
	;;
	delete )
		# 引数があったら終了
	    if [ $# -gt 1 ]; then echo "error!. you can use no parameter(s) here ."; exit 1; fi

		# PBSクラスタから全コンピュートノードを削除
		pbsvmip=$(az vm show -d -g $MyResourceGroup --name "${VMPREFIX}"-pbs --query publicIps -o tsv --only-show-errors)
		if [ -n "${pbsvmip}" ]; then
			# PBSジョブスケジューラから削除する
			echo "deleting node from PBS settings"
			# deletenodes.sh
			rm ./deletenodes.sh
			# vmlist はアクティブなVMのみ（停止されているVMはカウントされない）
			#input="./vmlist"
			#while IFS= read -r line
			#	do
			#		echo "/opt/pbs/bin/qmgr -c 'delete node $line'" >> deletenodes.sh
			#	done < "${input}"		
			#echo "deletenodes.sh: $(cat ./deletenodes.sh)"
			for count in $(seq 1 "$MAXVM") ; do
				echo "/opt/pbs/bin/qmgr -c 'delete node ${VMPREFIX}-${count}'" >> deletenodes.sh
			done
			scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./deletenodes.sh $USERNAME@"${pbsvmip}":/home/$USERNAME/deletenodes.sh
			# ジョブスケジューラセッティング変更：全コンピュートノード削除
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" root@"${pbsvmip}" -t -t "bash /home/$USERNAME/deletenodes.sh"
		fi

		# コンピュートノード削除
		if [ -f ./tmposdiskidlist ]; then rm ./tmposdiskidlist; fi
		for count in $(seq 1 "$MAXVM") ; do
			disktmp=$(az vm show -g $MyResourceGroup --name "${VMPREFIX}"-"${count}" --query storageProfile.osDisk.managedDisk.id -o tsv --only-show-errors)
			echo "$disktmp" >> tmposdiskidlist
		done
		echo "deleting compute VMs"
		seq 1 "$MAXVM" | parallel "az vm delete -g $MyResourceGroup --name ${VMPREFIX}-{} --yes &"
		numvm=$(cat ./vmlist | wc -l)

		# PBSノードの存在チェック
		osdiskidpbs=$(az vm show -g $MyResourceGroup --name "${VMPREFIX}"-pbs --query storageProfile.osDisk.managedDisk.id -o tsv --only-show-errors)
		if [ -n "$osdiskidpbs" ]; then
		#checkpbs=$(grep pbs ./hostsfile)
		#if [ -n "$checkpbs" ]; then
			# PBSノードが存在する場合
			while [ $((numvm)) -gt 2 ]; do
				echo "sleep 30" && sleep 30
				echo "current running VMs with PBS and Login node: $numvm"
				az vm list -g $MyResourceGroup | jq '.[] | .name' | grep "${VMPREFIX}" > ./vmlist
				numvm=$(cat ./vmlist | wc -l)
			done
		echo "deleted all compute VMs"
		else
			# PBSノードが存在しない場合
			while [ $((numvm)) -gt 0 ]; do
				echo "sleep 30" && sleep 30
				echo "current running VMs (no PBS): $numvm"
				az vm list -g $MyResourceGroup | jq '.[] | .name' | grep "${VMPREFIX}" > ./vmlist
				numvm=$(cat ./vmlist | wc -l)
			done
			echo "deleted all compute VMs. PBS node and login node exist"
		fi

		echo "deleting disk"
		parallel -a tmposdiskidlist "az disk delete --ids {} --yes"
		sleep 10
		# STATICMAC が true であればNIC、パブリックIPを再利用する
		if [ "$STATICMAC" == "true" ] || [ "$STATICMAC" == "TRUE" ]; then
			echo "keep existing nic and public ip"
		else
			echo "deleting nic"
			seq 1 "$MAXVM" | parallel "az network nic delete -g $MyResourceGroup --name ${VMPREFIX}-{}VMNic --only-show-errors"
			echo "deleting public ip"
			seq 1 "$MAXVM" | parallel "az network public-ip delete -g $MyResourceGroup --name ${VMPREFIX}-{}PublicIP --only-show-errors"
		fi
		echo "detele data disk"
		az disk delete -g $MyResourceGroup --name "${VMPREFIX}"-1-disk0 --yes
		echo "current running VMs: ${numvm}"

		# ファイル削除
		rm ./ipaddresslist
		rm ./tmposdiskidlist
		rm ./vmlist
		rm ./nodelist
		rm ./hostsfile
		# rm ./deletenodes.sh
	;;
	delete-all )
		# 引数があったら終了
	    if [ $# -gt 1 ]; then echo "error!. you can use no parameter(s) here ."; exit 1; fi

		if [ -f ./tmposdiskidlist ]; then
			rm ./tmposdiskidlist
		fi
		for count in $(seq 1 "$MAXVM") ; do
			disktmp=$(az vm show -g $MyResourceGroup --name "${VMPREFIX}"-"${count}" --query storageProfile.osDisk.managedDisk.id -o tsv --only-show-errors)
			echo "$disktmp" >> tmposdiskidlist
		done
		disktmp=$(az vm show -g $MyResourceGroup --name "${VMPREFIX}"-pbs --query storageProfile.osDisk.managedDisk.id -o tsv --only-show-errors)
		echo "$disktmp" >> tmposdiskidlist
		disktmp=$(az vm show -g $MyResourceGroup --name "${VMPREFIX}"-login --query storageProfile.osDisk.managedDisk.id -o tsv --only-show-errors)
		echo "$disktmp" >> tmposdiskidlist
		echo "deleting compute VMs"
		seq 1 "$MAXVM" | parallel "az vm delete -g $MyResourceGroup --name ${VMPREFIX}-{} --yes --only-show-errors &"
		echo "deleting pbs node"
		az vm delete -g $MyResourceGroup --name "${VMPREFIX}"-pbs --yes --only-show-errors &
		echo "deleting login node"
		az vm delete -g $MyResourceGroup --name "${VMPREFIX}"-login --yes --only-show-errors &
		# vmlistがある前提
		if [ ! -f "./vmlist" ]; then
			numvm=$(cat ./vmlist | wc -l)
		else
			numvm=$((MAXVM))
		fi
		# 停止：VM削除までの待ち時間
		while [ $((numvm)) -gt 0 ]; do
			echo "sleep 30" && sleep 30
			echo "current running VMs: $numvm"
			az vm list -g $MyResourceGroup | jq '.[] | .name' | grep "${VMPREFIX}" > ./vmlist
			numvm=$(cat ./vmlist | wc -l)
		done
		sleep 10 ##置換##
		echo "deleting disk"
		parallel -a tmposdiskidlist "az disk delete --ids {} --yes"
		sleep 10
		# STATICMAC が true であればNIC、パブリックIPを再利用する
		if [ "$STATICMAC" == "true" ] || [ "$STATICMAC" == "TRUE" ]; then
			echo "keep existing nic and public ip"
		else
			echo "deleting nic"
			seq 1 "$MAXVM" | parallel "az network nic delete -g $MyResourceGroup --name ${VMPREFIX}-{}VMNic" --only-show-errors
			az network nic delete -g $MyResourceGroup --name "${VMPREFIX}"-pbsVMNic
			az network nic delete -g $MyResourceGroup --name "${VMPREFIX}"-loginVMNic
			echo "deleting public ip"
			seq 1 "$MAXVM" | parallel "az network public-ip delete -g $MyResourceGroup --name ${VMPREFIX}-{}PublicIP" --only-show-errors
			az network public-ip delete -g $MyResourceGroup --name "${VMPREFIX}"-pbsPublicIP
			az network public-ip delete -g $MyResourceGroup --name "${VMPREFIX}"-loginPublicIP
		fi
		echo "detelting data disk"
		az disk delete -g $MyResourceGroup --name "${VMPREFIX}"-1-disk0 --yes
		az disk delete -g $MyResourceGroup --name "${VMPREFIX}"-pbs-disk0 --yes
		echo "current running VMs: ${numvm}"
		# ファイル削除
		rm ./ipaddresslist
		rm ./tmposdiskidlist
		rm ./vmlist
		rm ./config
		rm ./fullpingpong.sh
		rm ./pingponglist
		rm ./nodelist
		rm ./hostsfile
		rm ./tmpcheckhostsfile
		rm ./loginvmip
		rm ./pbsvmip
		rm ./md5*
		rm -rf ./openpbs*
		rm ./pbsprivateip
		rm ./loginpribateip
		rm ./checknfs.sh
		rm ./duplines.sh
		rm centosversion
		rm ./checksshtmp
		rm ./checkssh
		rm ./currentvm
		rm ./deletenode*.sh
	;;
	deletevm )
		# 引数 2 あったら終了
	    if [ $# -gt 2 ]; then echo "error!. you can use over 2 parameters here ."; exit 1; fi

		# 削除するVMとして $2 が必要
		echo "PBSノードとしてのノード削除の実施は実装中。PBSクラスタから削除されたかは、手動確認すること"

		pbsvmip=$(az vm show -d -g $MyResourceGroup --name "${VMPREFIX}"-pbs --query publicIps -o tsv --only-show-errors)
		if [ -n "${pbsvmip}" ]; then
			# PBSジョブスケジューラから削除する
			echo "deleting VM from PBS cluster..."
			# deletenode.sh
			rm ./deletenode.sh
			echo "/opt/pbs/bin/qmgr -c 'delete node ${VMPREFIX}-${2}'" >> deletenode.sh
			echo "deletenode.sh: $(cat ./deletenode.sh)"
			scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./deletenode.sh $USERNAME@"${pbsvmip}":/home/$USERNAME/deletenode.sh
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" root@"${pbsvmip}" -t -t "bash /home/$USERNAME/deletenode.sh"
		fi

		# 削除コンピュートノードOSディスク情報取得
		disktmp=$(az vm show -g $MyResourceGroup --name "${VMPREFIX}"-"${2}" --query storageProfile.osDisk.managedDisk.id -o tsv --only-show-errors)
		echo "deleting compute VMs"
		az vm delete -g $MyResourceGroup --name "${VMPREFIX}"-"${2}" --yes
		# 削除すべき行番号を割り出し
		tmpline=$(grep "${VMPREFIX}-${2}" -n ./vmlist | cut -d ":" -f 1)
		echo "$tmpline"
		echo "deliting line: $tmpline"
		# vmlistから特定のVMを削除
		sed -i -e "${tmpline}d" ./vmlist
		echo "show new current vmlist"
		cat ./vmlist
		# nodelistから特定のVMを削除
		sed -i -e "${tmpline}d" ./nodelist
		echo "show new current nodelist"
		cat ./nodelist
		# ディスク削除
		echo "deleting disk"
		az disk delete --ids "${disktmp}" --yes
		# STATICMAC が true であればNIC、パブリックIPを再利用する
		if [ "$STATICMAC" == "true" ] || [ "$STATICMAC" == "TRUE" ]; then
			echo "keep existing nic and public ip"
		else
			echo "deleting nic"
			az network nic delete -g $MyResourceGroup --name "${VMPREFIX}"-"${2}"VMNic
			echo "deleting public ip"
			az network public-ip delete -g $MyResourceGroup --name "${VMPREFIX}"-"${2}"PublicIP
		fi

		# ipaddresslistなど現在のコンピュートノードリストを再取得
		getipaddresslist vmlist ipaddresslist nodelist renew

		# ホストファイル修正：未実装
		gethostsfile

		echo "getting current number of VMs"
		az vm list-ip-addresses -g $MyResourceGroup --query "[].virtualMachine[].{Name:name}" -o tsv --only-show-errors > tmpfile
		# コンピュートノードのみ抽出
		grep -e "${VMPREFIX}-[1-99]" ./tmpfile > ./tmpfile2
		count=$(cat ./tmpfile2 | wc -l)
		echo "setting up VMs: $count"
		echo $((count)) > ./currentvm

		# ファイル削除
		rm ./tmpfile ./tmpfile2 
		#rm ./deletenode.sh

	;;
	remount )
		# 引数があったら終了
	    if [ $# -gt 1 ]; then echo "error!. you can use no parameter(s) here ."; exit 1; fi

		# mounting nfs server from compute node.
		if [ -f ./ipaddresslist ]; then rm ./ipaddresslist; fi
		getipaddresslist vmlist ipaddresslist

		echo "vm1 remounting..."
		mountdirectory vm1

		# PBSノード：展開済みかチェック
		echo "checking pbs node deployment...."
		pbsvmname=$(az vm show -d -g $MyResourceGroup --name "${VMPREFIX}"-pbs --query name -o tsv)
		if [ -n "$pbsvmname" ]; then
			echo "pbs remounting...."
			mountdirectory pbs
		fi
	;;
	pingpong )
		# 引数があったら終了
	    if [ $# -gt 1 ]; then echo "error!. you can use no parameter(s) here ."; exit 1; fi
		# 初期設定：ファイル削除
		if [ -f ./vmlist ]; then rm ./vmlist; fi
		if [ -f ./ipaddresslist ]; then rm ./ipaddresslist; fi
		if [ -f ./nodelist ]; then rm ./nodelist; fi
		echo "creating vmlist and ipaddresslist and nodelist"
		getipaddresslist vmlist ipaddresslist nodelist

		# pingponglist ファイルチェック・削除
		if [ -f ./pingponglist ]; then rm ./pingponglist; fi
		# pingponglist 作成：全ノードの組み合わせ作成
		for NODE in $(cat ./nodelist); do
			for NODE2 in $(cat ./nodelist); do
				echo "$NODE,$NODE2" >> pingponglist
			done
		done
		# fullpingpongコマンドスクリプト作成
		if [ -f ./fullpingpong.sh ]; then rm ./fullpingpong.sh; fi
		cat <<'EOL' >> fullpingpong.sh
#!/bin/bash
centosversion=$(cat /etc/redhat-release | cut  -d " " -f 4)
cp /home/$USER/* /mnt/resource/scratch/
cd /mnt/resource/scratch/
max=$(cat ./pingponglist | wc -l)
count=1
## TZ=JST-9 date
echo "========================================================================"
echo -n "$(TZ=JST-9 date '+%Y %b %d %a %H:%M %Z')" && echo " - pingpong #: $max, OS: ${centosversion}"
echo "========================================================================"
# run pingpong
case $centosversion in
	7.?.* )
		IMPI_VERSION=2018.4.274
		for count in `seq 1 $max`; do
			line=$(sed -n ${count}P ./pingponglist)
			echo "############### ${line} ###############"; >> result
			/opt/intel/impi/${IMPI_VERSION}/intel64/bin/mpirun -hosts $line -ppn 1 -n 2 -env I_MPI_FABRICS=shm:ofa /opt/intel/impi/${IMPI_VERSION}/bin64/IMB-MPI1 pingpong | grep -e ' 512 ' -e NODES -e usec; >> result
		done
	;;
	8.?.* )
		IMPI_VERSION=latest #2021.1.1
		 source /opt/intel/oneapi/mpi/${IMPI_VERSION}/env/vars.sh
		for count in `seq 1 $max`; do
			line=$(sed -n ${count}P ./pingponglist)
			echo "############### ${line} ###############"; >> result
			/opt/intel/oneapi/mpi/${IMPI_VERSION}/bin/mpiexec -hosts $line -ppn 1 -n 2 /opt/intel/oneapi/mpi/${IMPI_VERSION}/bin/IMB-MPI1 pingpong | grep -e ' 512 ' -e NODES -e usec; >> result
		done
	;;
esac
EOL
# ヒアドキュメントのルール上改行不可
		# SSHコンフィグファイルの再作成は必要ないため、削除
		if [ ! -f  ./config ]; then
			echo "no ssh config file in local directory!"
			cat <<'EOL' >> config
Host *
StrictHostKeyChecking no
UserKnownHostsFile=/dev/null
EOL

		fi
		# コマンド実行方法判断
		vm1ip=$(az vm show -d -g $MyResourceGroup --name "${VMPREFIX}"-1 --query publicIps -o tsv --only-show-errors)
		checkssh=$(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" "uname")
		for count in $(seq 1 10); do
			if [ -z "$checkssh" ]; then
				checkssh=$(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" "uname")
				echo "accessing VM#1 by ssh...." && sleep 2
			else
				break
			fi
		done
		if [ -n "$checkssh" ]; then
			# SSHアクセス可能：SSHでダイレクトに実施（早い）
			echo "running on direct access to all compute nodes"
			# fullpingpong実行
			echo "pingpong: show pingpong combination between nodes"
			cat ./pingponglist
			scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./fullpingpong.sh $USERNAME@"${vm1ip}":/home/$USERNAME/
			scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./pingponglist $USERNAME@"${vm1ip}":/home/$USERNAME/
			scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./fullpingpong.sh $USERNAME@"${vm1ip}":/mnt/resource/scratch/
			scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./pingponglist $USERNAME@"${vm1ip}":/mnt/resource/scratch/
			# SSH追加設定
			cat ./ipaddresslist
			echo "pingpong: copy passwordless settings"
			seq 1 "$MAXVM" | parallel -a ipaddresslist "scp -o StrictHostKeyChecking=no -i ${SSHKEYDIR} ./config $USERNAME@{}:/home/$USERNAME/.ssh/config"
			seq 1 "$MAXVM" | parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@{} -t -t "chmod 600 /home/$USERNAME/.ssh/config""
			# コマンド実行
			echo "pingpong: running pingpong for all compute nodes"
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "rm /mnt/resource/scratch/result"
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "bash /mnt/resource/scratch/fullpingpong.sh > /mnt/resource/scratch/result"
			echo "copying the result from vm1 to local"
			scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}":/mnt/resource/scratch/result ./
			ls -la ./*result*
			cat ./result
			echo "ローカルのresultファイルを確認"
		else
			# SSHアクセス不可能：ログインノード経由で設定
			echo "running via loging node due to limited access to all compute nodes"
			for count in $(seq 1 "${MAXVM}"); do
				loginprivateip=$(az vm show -g $MyResourceGroup --name "${VMPREFIX}"-login -d --query privateIps -o tsv --only-show-errors)
				vm1privateip=$(az vm show -g $MyResourceGroup --name "${VMPREFIX}"-1 -d --query privateIps -o tsv --only-show-errors)
				checkssh2=$(ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "uname")
				for cnt in $(seq 1 10); do
					if [ -n "$checkssh2" ]; then
						break
					else
						echo "sleep 10" && sleep 1
					fi
				done
				if [ -z "$checkssh2" ]; then
					echo "error!: you can not access by ssh the login node!"
					exit 1
				fi
				# ファイル転送: local to login node
				echo "ローカル: ssh: ホストファイル転送 transfer login node"
				scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./fullpingpong.sh $USERNAME@"${loginvmip}":/home/$USERNAME/
				scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./pingponglist $USERNAME@"${loginvmip}":/home/$USERNAME/
				scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./fullpingpong.sh $USERNAME@"${loginvmip}":/mnt/resource/scratch/
				scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./pingponglist $USERNAME@"${loginvmip}":/mnt/resource/scratch/
				# ファイル転送: login node to VM#1
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "scp -o StrictHostKeyChecking=no -i ${SSHKEYDIR} ./fullpingpong.sh $USERNAME${vm1privateip}:/home/$USERNAME/"
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "scp -o StrictHostKeyChecking=no -i ${SSHKEYDIR} ./pingponglist $USERNAME@${vm1privateip}:/home/$USERNAME/"
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "scp -o StrictHostKeyChecking=no -i ${SSHKEYDIR} ./fullpingpong.sh $USERNAME@${vm1privateip}:/mnt/resource/scratch/"
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "scp -o StrictHostKeyChecking=no -i ${SSHKEYDIR} ./pingponglist $USERNAME@${vm1privateip}:/mnt/resource/scratch/"
				# pingpongコマンド実行
				echo "pingpong: running pingpong for all compute nodes"
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${vm1privateip} -t -t 'rm /mnt/resource/scratch/result'"
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${vm1privateip} -t -t "bash /mnt/resource/scratch/fullpingpong.sh > /mnt/resource/scratch/result""
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "scp -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${vm1privateip}:/mnt/resource/scratch/result /home/$USERNAME/"
				# 多段の場合、ローカルにもダウンロードが必要
				echo "copying the result from vm1 to local"
				scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1privateip}":/home/$USERNAME/ ./
				ls -la ./*result*
				cat ./result
				echo "ローカルのresultファイルを確認"
			done
		fi
	;;
	updatensg )
		# NSGアップデート：既存の実行ホストからのアクセスを修正
		echo "current host global ip address: $LIMITEDIP"
		echo "updating NSG for current host global ip address"
		az network nsg rule update --name ssh --nsg-name $MyNetworkSecurityGroup -g $MyResourceGroup --access allow --protocol Tcp --direction Inbound \
			--priority 1000 --source-address-prefix "$LIMITEDIP" --source-port-range "*" --destination-address-prefix "*" --destination-port-range 22 -o table --only-show-errors
		az network nsg rule update --name ssh2 --nsg-name $MyNetworkSecurityGroup -g $MyResourceGroup --access allow --protocol Tcp --direction Inbound \
			--priority 1010 --source-address-prefix $LIMITEDIP2 --source-port-range "*" --destination-address-prefix "*" --destination-port-range 22 -o table --only-show-errors
	;;
	privatenw )
		# PBSノード、コンピュートノード：インターネットからの外部接続を削除
		echo "既存のクラスターからインターネットとの外部接続（パブリックIP）を削除"
		count=0
		for count in $(seq 1 "$MAXVM"); do
			tmpipconfig=$(az network nic ip-config list --nic-name "${VMPREFIX}"-"${count}"VMNic -g $MyResourceGroup -o tsv --query [].name)
			az network nic ip-config update --name "$tmpipconfig" -g $MyResourceGroup --nic-name "${VMPREFIX}"-"${count}"VMNic --remove publicIpAddress -o table --only-show-errors &
		done
		# PBSノードも同様にインターネットからの外部接続を削除
		tmpipconfig=$(az network nic ip-config list --nic-name "${VMPREFIX}"-pbsVMNic -g $MyResourceGroup -o tsv --query [].name)
		az network nic ip-config update --name "$tmpipconfig" -g $MyResourceGroup --nic-name "${VMPREFIX}"-pbsVMNic --remove publicIpAddress -o table --only-show-errors &
	;;
	publicnw )
		# PBSノード、コンピュートノード：インターネットとの外部接続を確立
		echo "既存のクラスターからインターネットとの外部接続を確立（パブリックIP付与）"
		count=0
		for count in $(seq 1 "$MAXVM"); do
			tmpipconfig=$(az network nic ip-config list --nic-name "${VMPREFIX}"-"${count}"VMNic -g $MyResourceGroup -o tsv --query [].name)
			az network nic ip-config update --name ipconfig"${VMPREFIX}"-"${count}" -g $MyResourceGroup --nic-name "${VMPREFIX}"-"${count}"VMNic --public "${VMPREFIX}"-"${count}"PublicIP -o table --only-show-errors &
		done
		# PBSノードも同様にインターネットからの外部接続を追加
		tmpipconfig=$(az network nic ip-config list --nic-name "${VMPREFIX}"-pbsVMNic -g $MyResourceGroup -o tsv --query [].name)
		az network nic ip-config update --name ipconfig"${VMPREFIX}"-pbs -g $MyResourceGroup --nic-name "${VMPREFIX}"-pbsVMNic --public "${VMPREFIX}"-pbsPublicIP -o table --only-show-errors &
	;;
	listip )
		# IPアドレスを表示
		az vm list-ip-addresses -g $MyResourceGroup --query "[].virtualMachine.{VirtualMachine:name,PrivateIPAddresses:network.privateIpAddresses[0],PublicIp:network.publicIpAddresses[0].ipAddress}" -o table --only-show-errors
	;;
	ssh )
		# SSHアクセスコマンド
		# ex. ./hpcbmtenv.sh ssh 1  ./hpcbmtenv.sh ssh pbs  ./hpcbmtenv.sh ssh login
		case ${2} in
			login )
				loginvmip=$(az vm show -d -g $MyResourceGroup --name "${VMPREFIX}"-pbs --query publicIps -o tsv)
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}"
			;;
			pbs )
				pbsvmip=$(az vm show -d -g $MyResourceGroup --name "${VMPREFIX}"-pbs --query publicIps -o tsv)
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}"
			;;
			* )
				line=$(sed -n "${2}"P ./ipaddresslist)
				cmd=$(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" uname)
				if [ "$cmd" = "Linux" ]; then
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}"
				else
					if [ ! -f ./ipaddresslist ]; then
						getipaddresslist vmlist ipaddresslist
					fi
					vm1ip=$(az vm show -d -g $MyResourceGroup --name "${VMPREFIX}"-1 --query publicIps -o tsv)
					vm1ipexist=$(sed -n 1P ./ipaddresslist)
					if [ "${vm1ip}" != "${vm1ipexist}" ]; then
						#rm ./vmlist ./ipaddresslist
						getipaddresslist vmlist ipaddresslist
					fi	
					line=$(sed -n "${2}"P ./ipaddresslist)
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}"
				fi
			;;
		esac
	;;
	checkfiles )
		# 利用するローカルスクリプトを作成
		echo "create scripts in local directory"
### ===========================================================================
		rm checkmount.sh
		# VMマウントチェックスクリプト
		cat <<'EOL' >> checkmount.sh
#!/bin/bash
#VMPREFIX=sample
#USERNAME=sample

# SSH秘密鍵ファイルのディレクトリ決定
tmpfile=$(stat ./${VMPREFIX} -c '%a')
case $tmpfile in
	600 )
		SSHKEYDIR="./${VMPREFIX}"
	;;
	7** )
		cp ./${VMPREFIX} $HOME/.ssh/
		chmod 600 $HOME/.ssh/${VMPREFIX}
		SSHKEYDIR="$HOME/.ssh/${VMPREFIX}"
	;;
esac
echo "SSHKEYDIR: $SSHKEYDIR"
vm1ip=$(sed -n 1P ./ipaddresslist)
ssh -i $SSHKEYDIR $USERNAME@${vm1ip} -t -t 'sudo showmount -e'
parallel -v -a ipaddresslist "ssh -i $SSHKEYDIR $USERNAME@{} -t -t 'df -h | grep 10.0.0.'"
EOL
		VMPREFIX=$(grep "VMPREFIX=" "${CMDNAME}" | head -n 1 | cut -d "=" -f 2)
		sed -i -e "s/^#VMPREFIX=sample/VMPREFIX=$VMPREFIX/" ./checkmount.sh
		SSHKEYDIR=$(grep "SSHKEYDIR=" "${CMDNAME}" | sed -n 2p | cut -d "=" -f 2)
		sed -i -e "s:^#SSHKEYDIR=sample:SSHKEYDIR=$SSHKEYDIR:" ./checkmount.sh
		USERNAME=$(grep "USERNAME=" "${CMDNAME}" | head -n 1 | cut -d "=" -f 2)
		sed -i -e "s/^#USERNAME=sample/USERNAME=$USERNAME/" ./checkmount.sh
### ===========================================================================
		rm checktunnel.sh
		# VM LISTENチェックスクリプト
		cat <<'EOL' >> checktunnel.sh
#!/bin/bash
#VMPREFIX=sample
#USERNAME=sample

# SSH秘密鍵ファイルのディレクトリ決定
tmpfile=$(stat ./${VMPREFIX} -c '%a')
case $tmpfile in
	600 )
		SSHKEYDIR="./${VMPREFIX}"
	;;
	7** )
		cp ./${VMPREFIX} $HOME/.ssh/
		chmod 600 $HOME/.ssh/${VMPREFIX}
		SSHKEYDIR="$HOME/.ssh/${VMPREFIX}"
	;;
esac
echo "SSHKEYDIR: $SSHKEYDIR"
seq 1 $MAXVM | parallel -v -a ipaddresslist "ssh -i $SSHKEYDIR azureuser@{} -t -t 'netstat -an | grep -v -e :22 -e 80 -e 443 -e 445'"
EOL
		VMPREFIX=$(grep "VMPREFIX=" "${CMDNAME}" | head -n 1 | cut -d "=" -f 2)
		sed -i -e "s/^#VMPREFIX=sample/VMPREFIX=$VMPREFIX/" ./checktunnel.sh
		SSHKEYDIR=$(grep "SSHKEYDIR=" "${CMDNAME}" | sed -n 2p | cut -d "=" -f 2)
		sed -i -e "s:^#SSHKEYDIR=sample:SSHKEYDIR=$SSHKEYDIR:" ./checktunnel.sh
		USERNAME=$(grep "USERNAME=" "${CMDNAME}" | head -n 1 | cut -d "=" -f 2)
		sed -i -e "s/^#USERNAME=sample/USERNAME=$USERNAME/" ./checktunnel.sh
### ===========================================================================
		rm createnodelist.sh
		# VMプライベートIPアドレスリスト作成スクリプト
		cat <<'EOL' >> createnodelist.sh
#!/bin/bash
#MAXVM=2
#MyResourceGroup=sample
#VMPREFIX=sample

# ホストファイル作成準備：既存ファイル削除
if [ -f ./nodelist ]; then rm ./nodelist; echo "recreating a new nodelist"; fi
# ホストファイル作成
az vm list-ip-addresses -g $MyResourceGroup --query "[].virtualMachine.{VirtualMachine:name,PrivateIPAddresses:network.privateIpAddresses[0]}" -o tsv > tmphostsfile
# 自然な順番でソートする
sort -V ./tmphostsfile > hostsfile
# nodelist 取り出し：2列目
cat hostsfile | cut -f 2 > nodelist
# テンポラリファイル削除
rm ./tmphostsfile
EOL
		MyResourceGroup=$(grep "MyResourceGroup=" "${CMDNAME}" | head -n 1 | cut -d "=" -f 2)
		sed -i -e "s/^#MyResourceGroup=sample/MyResourceGroup=$MyResourceGroup/" ./createnodelist.sh
		MAXVM=$(grep "MAXVM=" "${CMDNAME}" | head -n 1 | cut -d "=" -f 2)
		sed -i -e "s/^#MAXVM=sample/MAXVM=$MAXVM/" ./createnodelist.sh
		VMPREFIX=$(grep "VMPREFIX=" "${CMDNAME}" | head -n 1 | cut -d "=" -f 2)
		sed -i -e "s/^#VMPREFIX=sample/VMPREFIX=$VMPREFIX/" ./createnodelist.sh
		echo "end of creating script files"
	;;
	tfsetup )
		# terraform 環境向け設定コマンド： terraformが構成した環境について追加設定をする
		# vmlist and ipaddress 作成
		getipaddresslist vmlist ipaddresslist

		# すべてのコンピュートノードにSSH可能なら checkssh に変数を代入
		checksshconnection all
		#checksshconnection vm1

		# コンピュートノード：all computenodes: basicsettings - locale, sudo, passwordless, sshd
		basicsettings all

		checksshconnection pbs

		# PBSノード：all computenodes: basicsettings - locale, sudo, passwordless, sshd
		basicsettings pbs

		checksshconnection vm1

		# VM1 NFSサーバ設定
		echo "setting up vm1 nfs server"
		vm1ip=$(az vm show -d -g $MyResourceGroup --name "${VMPREFIX}"-1 --query publicIps -o tsv --only-show-errors)
		echo "checkssh connectiblity for ${VMPREFIX}-1: $checkssh"
		checksshconnection vm1
		if [ -z "$checkssh" ]; then
			az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-1 --command-id RunShellScript \
				--scripts "sudo yum install --quiet -y nfs-utils epel-release && echo '/mnt/resource/scratch *(rw,no_root_squash,async)' >> /etc/exports"
			az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-1 --command-id RunShellScript --scripts "sudo yum install --quiet -y htop"
			sleep 5
			az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-1 --command-id RunShellScript --scripts "sudo mkdir -p /mnt/resource/scratch"
			az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-1 --command-id RunShellScript --scripts "sudo chown ${USERNAME}:${USERNAME} /mnt/resource/scratch"
			az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-1 --command-id RunShellScript --scripts "sudo systemctl start rpcbind && sudo systemctl start nfs-server"
			#az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-1 --command-id RunShellScript --scripts "sudo systemctl enable rpcbind && sudo systemctl enable nfs-server"
		else
			# SSH設定が高速なため、checkssh が有効な場合、SSHで実施
			echo "${VMPREFIX}-1: sudo 設定"
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "sudo cat /etc/sudoers | grep $USERNAME" > sudotmp
			if [ -z "$sudotmp" ]; then
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "echo "$USERNAME ALL=NOPASSWD: ALL" | sudo tee -a /etc/sudoers"
			fi
			unset sudotmp && rm ./sudotmp
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "sudo cat /etc/sudoers | grep $USERNAME"
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "sudo yum install --quiet -y nfs-utils epel-release"
			# アフターインストール：epel-release
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "sudo yum install --quiet -y htop"
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "echo '/mnt/resource/scratch *(rw,no_root_squash,async)' | sudo tee /etc/exports"
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "sudo mkdir -p /mnt/resource/scratch"
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "sudo chown ${USERNAME}:${USERNAME} /mnt/resource/scratch"
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "sudo systemctl start rpcbind && sudo systemctl start nfs-server"
			#ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "sudo systemctl enable rpcbind && sudo systemctl enable nfs-server"
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "sudo showmount -e"
		fi

		# PBSノード：ディスクフォーマット
		echo "pbsnode: /dev/sdc disk formatting"
		diskformat=$(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "df | grep sdc1")
		echo "diskformat: $diskformat"
		# リモートの /dev/sdc が存在する
		diskformat2=$(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo ls /dev/sdc 2> /dev/null")
		echo "diskformat2: $diskformat2"
		if [ -n "$diskformat2" ]; then
			# かつ、 /dev/sdc1 が存在しない場合のみ実施
			diskformat3=$(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo ls /dev/sdc1")
			if [[ $diskformat3 != "/dev/sdc1" ]]; then
				# /dev/sdc1が存在しない (not 0)場合のみ実施
				# リモートの /dev/sdc が未フォーマットであるか
				disktype1=$(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo fdisk -l /dev/sdc | grep 'Disk label type'")
				disktype2=$(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo fdisk -l /dev/sdc | grep 'Disk identifier'")
				# どちらも存在しない場合、フォーマット処理
				if [[ -z "$disktype1" ]] || [[ -z "$disktype2" ]] ; then
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo parted /dev/sdc --script mklabel gpt mkpart xfspart xfs 0% 100%"
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo mkfs.xfs /dev/sdc1"
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo partprobe /dev/sdc1"
					echo "pbsnode: fromatted a new disk."
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "df | grep sdc1"
				else
					echo "your pbs node has not the device."
				fi
			fi
		fi
		# リモートの /dev/sdb が存在する
		diskformat3=$(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo ls /dev/sdb")
		echo "diskformat3: $diskformat3"
		if [ -n "$diskformat3" ]; then
			# かつ、 /dev/sdb1 が存在しない場合のみ実施
			diskformat4=$(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo ls /dev/sdb1")
			if [[ $diskformat4 != "/dev/sdc1" ]]; then
				# /dev/sdb1が存在しない (not 0)場合のみ実施
				# リモートの /dev/sdc が未フォーマットであるか
				disktype3=$(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo fdisk -l /dev/sdb | grep 'Disk label type'")
				disktype4=$(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo fdisk -l /dev/sdb | grep 'Disk identifier'")
				# どちらも存在しない場合、フォーマット処理
				if [[ -z "$disktype3" ]] || [[ -z "$disktype4" ]] ; then
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo parted /dev/sdb --script mklabel gpt mkpart xfspart xfs 0% 100%"
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo mkfs.xfs /dev/sdb1"
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo partprobe /dev/sdb1"
					echo "pbsnode: fromatted a new disk."
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "df | grep sdb1"
				fi
			fi
		fi

		unset diskformat && unset diskformat2 && unset diskformat3

		# PBSノード：ディレクトリ設定
		echo "pbsnode: data directory setting"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo mkdir -p /mnt/share"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo mount /dev/sdc1 /mnt/share"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo mount /dev/sdb1 /mnt/share"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo chown $USERNAME:$USERNAME /mnt/share"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "ls -la /mnt"
		# NFS設定
		echo "pbsnode: nfs server settings"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo yum install --quiet -y nfs-utils epel-release"
		# アフターインストール：epel-release
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo yum install --quiet -y md5sum htop"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "echo '/mnt/share *(rw,no_root_squash,async)' | sudo tee /etc/exports"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo systemctl start rpcbind && sudo systemctl start nfs-server"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo systemctl enable rpcbind && sudo systemctl enable nfs-server"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo showmount -e"

		# NFSサーバ・マウント設定
		echo "${VMPREFIX}-2 to ${MAXVM}: mouting VM#1"
		mountdirectory vm1
		echo "${VMPREFIX}-2 to ${MAXVM}: end of mouting ${mountip}:/mnt/resource/scratch"
		mountdirectory pbs

		# ホストファイル作成（作成のみ）
		gethostsfile

		#
		pbsvmip=$(az vm show -d -g $MyResourceGroup --name "${VMPREFIX}"-pbs --query publicIps -o tsv)

		# PBSノード：ホストファイル転送・更新
		checkssh=$(ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i "${SSHKEYDIR}" -t $USERNAME@"${pbsvmip}" "uname")
		if [ -n "$checkssh" ]; then
			# ssh成功すれば実施
			echo "${VMPREFIX}-pbs: updating hosts file by ssh"
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "rm /home/$USERNAME/hostsfile"
			scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./hostsfile $USERNAME@"${pbsvmip}":/home/$USERNAME/
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo cp /etc/hosts.original /etc/hosts"
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "cat /home/$USERNAME/hostsfile | sudo tee -a /etc/hosts"
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo cat /etc/hosts | grep ${VMPREFIX}"
		else
			# SSH失敗した場合、az vm run-commandでのホストファイル転送・更新
			echo "${VMPREFIX}-pbs: updating hosts file by az vm running command"
			# ログインノードIPアドレス取得：空なら再取得
			loginvmip=$(cat ./loginvmip)
			if [ -n "$loginvmip" ]; then
				loginvmip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-login --query publicIps -o tsv)
			fi
			echo "loginvmip: $loginvmip"
			echo "PBSノード: ssh: ホストファイル転送 local to login node"
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "rm /home/$USERNAME/hostsfile"
			scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./hostsfile $USERNAME@"${loginvmip}":/home/$USERNAME/
			if [ ! -s "./*.tfvars" ]; then
				scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./${VMPREFIX} $USERNAME@"${loginvmip}":/home/$USERNAME/${VMPREFIX}
			else
				# terraformファイルが存在する場合、 ~/.ssh/id_rsa 利用を優先する
				scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ~/.ssh/id_rsa $USERNAME@"${loginvmip}":/home/$USERNAME/${VMPREFIX}
			fi
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "chmod 600 /home/$USERNAME/${VMPREFIX}"
			echo "PBSノード: ssh: ホストファイル転送 ログインノード to PBSノード"
			az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-pbs --command-id RunShellScript --scripts "scp -o StrictHostKeyChecking=no -i /home/$USERNAME/${VMPREFIX} $USERNAME@${loginprivateip}:/home/$USERNAME/hostsfile /home/$USERNAME/"
			echo "PBSノード: az: ホストファイル更新"
			az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-pbs --command-id RunShellScript --scripts "sudo cp /etc/hosts.original /etc/hosts"
			# az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-pbs --command-id RunShellScript --scripts "cat /home/$USERNAME/hostsfile | sudo tee -a /etc/hosts"
			az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-pbs --command-id RunShellScript --scripts "cat /etc/hosts"
		fi
		
		# コンピュートノード：ホストファイル転送・更新
		echo "copy hostsfile to all compute nodes"
		count=0
		for count in $(seq 1 $MAXVM); do
			line=$(sed -n "${count}"P ./ipaddresslist)
			# ログインノードへのSSHアクセスチェック
			loginvmip=$(cat ./loginvmip)
			if [ -n "$loginvmip" ]; then
				loginvmip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-login --query publicIps -o tsv)
			fi
			echo "loginvmip: $loginvmip"
			# コンピュートノードへの直接SSHアクセスチェック
			vm1ip=$(az vm show -d -g $MyResourceGroup --name ${VMPREFIX}-1 --query publicIps -o tsv)
			checkssh=$(ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "uname")
			echo "checkssh: $checkssh"
			if [ -n "$checkssh" ]; then
				echo "${VMPREFIX}-1 to ${MAXVM}: updating hostsfile by ssh(direct)"
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "rm /home/$USERNAME/hostsfile"
				scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./hostsfile $USERNAME@"${line}":/home/$USERNAME/
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "sudo cp /etc/hosts.original /etc/hosts"
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "sudo cp /home/$USERNAME/hostsfile /etc/hosts"
				echo "${VMPREFIX}-${count}: show new hosts file"
				ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "sudo cat /etc/hosts | grep ${VMPREFIX}"
			else
				# ログインノード経由で設定
				checkssh2=$(ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "uname")
				if [ -n "$checkssh2" ]; then
					echo "${VMPREFIX}-1 to ${MAXVM}: updating hostsfile by ssh(via login node)"
					# 多段SSH
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${line} -t -t "rm /home/$USERNAME/hostsfile""
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "scp -o StrictHostKeyChecking=no -i ${SSHKEYDIR} ./hostsfile $USERNAME@${line}:/home/$USERNAME/"
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${line} -t -t "sudo cp /etc/hosts.original /etc/hosts""
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${line} -t -t "sudo cp /home/$USERNAME/hostsfile /etc/hosts""
					echo "${VMPREFIX}-${count}: show new hosts file"
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "ssh -o StrictHostKeyChecking=no -i ${SSHKEYDIR} $USERNAME@${line} -t -t "sudo cat /etc/hosts | grep ${VMPREFIX}""
				else
					# SSHできないため、az vm run-commandでのホストファイル転送・更新
					echo "${VMPREFIX}-${count}: updating hosts file by az vm running command"
					# ログインノードIPアドレス取得：取得済み
					echo "loginvmip: $loginvmip"
					echo "ローカル: ssh: ホストファイル転送 transfer login node"
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "rm /home/$USERNAME/hostsfile"
					scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./hostsfile $USERNAME@"${loginvmip}":/home/$USERNAME/
					if [ ! -s "./*.tfvars" ]; then
						scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./${VMPREFIX} $USERNAME@"${loginvmip}":/home/$USERNAME/
					else
						# terraformファイルが存在する場合、 ~/.ssh/id_rsa 利用を優先する
						scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ~/.ssh/id_rsa $USERNAME@"${loginvmip}":/home/$USERNAME/
					fi
					ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${loginvmip}" -t -t "chmod 600 /home/$USERNAME/${VMPREFIX}"
					# ログインプライベートIPアドレス取得：すでに取得済み
					#loginprivateip=$(az vm show -g $MyResourceGroup --name ${VMPREFIX}-login -d --query privateIps -o tsv)
					for count2 in $(seq 1 $MAXVM); do
						# ログインノードへはホストファイル転送済み
						echo "コンピュートノード： az: ホストファイル転送 login to compute node"
						az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-"${count2}" --command-id RunShellScript --scripts "scp -o StrictHostKeyChecking=no -i /home/$USERNAME/${VMPREFIX} $USERNAME@${loginprivateip}:/home/$USERNAME/hostsfile /home/$USERNAME/"
						echo "コンピュートノード： az: ホストファイル更新"
						az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-"${count2}" --command-id RunShellScript --scripts "sudo cp /etc/hosts.original /etc/hosts"
						az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-"${count2}" --command-id RunShellScript --scripts "sudo cp /home/$USERNAME/hostsfile /etc/hosts"
						az vm run-command invoke -g $MyResourceGroup --name ${VMPREFIX}-"${count2}" --command-id RunShellScript --scripts "sudo cat /etc/hosts"
					done
				fi
			fi
		done
		# ホストファイル更新完了
		echo "end of hostsfile update"

		# ローカル：OpenPBSパッケージダウンロード
		wget -q -N https://github.com/openpbs/openpbs/releases/download/v20.0.1/openpbs_20.0.1.centos_8.zip -O ./openpbs_20.0.1.centos_8.zip
		unzip -qq -o ./openpbs_20.0.1.centos_8.zip
		# https://groups.io/g/OpenHPC-users/topic/cannot_install_slurm_due_to/78463158?p=,,,20,0,0,0::recentpostdate%2Fsticky,,,20,2,0,78463158 の問題対応
		wget -q -N http://mirror.centos.org/centos/7/os/x86_64/Packages/hwloc-libs-1.11.8-4.el7.x86_64.rpm -O ./openpbs_20.0.1.centos_8/hwloc-libs-1.11.8-4.el7.x86_64.rpm
		
		# PBSノード：OpenPBSサーババイナリコピー＆インストール
		# PBSノード：OpenPBSクライアントコピー
		echo "CentOS8.x: copy openpbs-execution-20.0.1-0.x86_64.rpm to all compute nodes"
		#scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i "${SSHKEYDIR}" ./openpbs_20.0.1.centos_8/openpbs-client-20.0.1-0.x86_64.rpm $USERNAME@"${pbsvmip}":/home/$USERNAME/
		#scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i "${SSHKEYDIR}" ./openpbs_20.0.1.centos_8/openpbs-server-20.0.1-0.x86_64.rpm $USERNAME@"${pbsvmip}":/home/$USERNAME/
		#scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i "${SSHKEYDIR}" ./openpbs_20.0.1.centos_8/hwloc-libs-1.11.8-4.el7.x86_64.rpm $USERNAME@"${pbsvmip}":/home/$USERNAME/

		# コンピュートノード：OpenPBSクライアントバイナリコピー＆インストール
		parallel -a ipaddresslist "scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} ./openpbs_20.0.1.centos_8/hwloc-libs-1.11.8-4.el7.x86_64.rpm $USERNAME@${pbsvmip}:/home/$USERNAME/"
		parallel -a ipaddresslist "scp -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} ./openpbs_20.0.1.centos_8/openpbs-execution-20.0.1-0.x86_64.rpm $USERNAME@{}:/home/$USERNAME/"
		
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo dnf install --quiet -y /home/$USERNAME/hwloc-libs-1.11.8-4.el7.x86_64.rpm""
		for count in $(seq 1 $MAXVM) ; do
			line=$(sed -n "${count}"P ./ipaddresslist)
			cmd=$(ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "sudo rpm -aq | grep hwloc")
			if [ -n "$cmd" ]; then
				parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo dnf install --quiet -y /home/$USERNAME/openpbs-execution-20.0.1-0.x86_64.rpm""
			else
				echo "error!: this VM did not install hwloc"
				exit 1
			fi
		done
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t 'sudo rpm -aq | grep openpbs'"
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t 'sudo /opt/pbs/libexec/pbs_habitat'"
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t 'sudo /opt/pbs/libexec/pbs_postinstall'"
		# コンピュートノード：pbs.confファイル生成
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo sed -i -e 's/PBS_START_MOM=0/PBS_START_MOM=1/g' /etc/pbs.conf""
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo sed -i -e s/CHANGE_THIS_TO_PBS_SERVER_HOSTNAME/${VMPREFIX}-pbs/g /etc/pbs.conf""
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo cat /etc/pbs.conf""
		# コンピュートノード：OpenPBSクライアント：パーミッション設定
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t 'sudo chmod 4755 /opt/pbs/sbin/pbs_iff'"
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t 'sudo chmod 4755 /opt/pbs/sbin/pbs_rcp'"
		# コンピュートノード：OpenPBSクライアント：/var/spool/pbs/mom_priv/config コンフィグ設定
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t "sudo sed -i -e s/CHANGE_THIS_TO_PBS_SERVER_HOSTNAME/${VMPREFIX}-pbs/g /var/spool/pbs/mom_priv/config""
		for count in $(seq 1 $MAXVM) ; do
			line=$(sed -n "${count}"P ./ipaddresslist)
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${line}" -t -t "sudo sed -i -e s/CHANGE_THIS_TO_PBS_SERVER_HOSTNAME/${VMPREFIX}-pbs/g /var/spool/pbs/mom_priv/config"
		done

### ===========================================================================
		# PBSプロセス起動
		# PBSノード起動＆$USERNAME環境変数設定
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "grep pbs.sh /home/azureuser/.bashrc" > ./pbssh
		pbssh=$(cat ./pbssh)
		if [ -z "$pbssh" ]; then
			ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "yes | sudo /etc/init.d/pbs start"
		fi
		# OpenPBSクライアントノード起動＆$USERNAME環境変数設定
		parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t 'sudo /etc/init.d/pbs start'"
		vm1ip=$(az vm show -d -g $MyResourceGroup --name "${VMPREFIX}"-1 --query publicIps -o tsv --only-show-errors)
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${vm1ip}" -t -t "grep pbs.sh /home/azureuser/.bashrc" > ./pbssh
		pbssh=$(cat ./pbssh)
		if [ -z "$pbssh" ]; then
			parallel -a ipaddresslist "ssh -o StrictHostKeyChecking=no -o 'ConnectTimeout 30' -i ${SSHKEYDIR} $USERNAME@{} -t -t 'echo 'source /etc/profile.d/pbs.sh' >> $HOME/.bashrc'"
		fi
		rm ./pbssh
		echo "finished to set up additonal login and PBS node"
### ===========================================================================
		# PBSジョブスケジューラセッティング
		echo "configpuring PBS settings"
		rm ./setuppbs.sh
		for count in $(seq 1 $MAXVM); do
			echo "/opt/pbs/bin/qmgr -c 'create node ${VMPREFIX}-${count}'" >> setuppbs.sh
		done
		sed -i -e "s/-c /-c '/g" setuppbs.sh
		sed -i -e "s/$/\'/g" setuppbs.sh
		echo "setuppbs.sh: $(cat ./setuppbs.sh)"
		scp -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" ./setuppbs.sh "$USERNAME"@"${pbsvmip}":/home/$USERNAME/setuppbs.sh
		# SSH鍵登録
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo cp /root/.ssh/authorized_keys /root/.ssh/authorized_keys.old"
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" $USERNAME@"${pbsvmip}" -t -t "sudo cp /home/$USERNAME/.ssh/authorized_keys /root/.ssh/authorized_keys"
		# ジョブスケジューラセッティング
		ssh -o StrictHostKeyChecking=no -i "${SSHKEYDIR}" root@"${pbsvmip}" -t -t "bash /home/$USERNAME/setuppbs.sh"
		rm ./setuppbs.sh
	echo "end of tfsetup"
	;;
esac


echo "$CMDNAME: end of vm hpc environment create script"
