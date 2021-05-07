# hpcbmtenv

Azure上でHPCベンチマークを作成するBashスクリプトです。
スクリプトは、VMベースで作成されVMSSやAzure CycleCloudは利用しません。

## コマンドについて
実行するには1,2,3個の引数が必要です。

create,delete,start,stop,stop-all,list,remount,pingpong,addlogin,updatensg,privatenw,publicnw の引数を一つ指定する必要があります。
引数2,3は以下のコマンドのみ利用されます。
- stopvm $1
- stopvm $1 $2
- startvm $1

## その他のコマンド
 - stop: すべてのコンピュートノードを停止します。
 - stop-all: すべてのコンピュートノード＋PBSノード・ログインノードもすべて停止します。
 - stopvm <vm#>: コンピュートノードVM#のみを停止します。
 - stopvms <start vm#> <end vm#>: コンピュートノードVM# xからVM# yまで停止します。
 - startvm <vm#>: コンピュートノードVM#を起動します。
 - list: VMの状況・およびマウンド状態を表示します。
 - listip: IPアドレスアサインの状態を表示します。
 - pingpong: すべてのノード間でpingpongを取得します。ローカルファイル result に保存します。
 - remount: デフォルトで設定されているディレクトリの再マウントを実施します。
 - publicnw コマンド: コンピュートノード、PBSノードからグローバルIPアドレスを再度追加します。
 - delete: すべてのコンピュートノードを削除します。
 - delete-all: すべてのコンピュートノード、PBSノード、ログインノードを削除します。
 - deletevm <vm#>: 特定のコンピュートノード#のみを削除します。(PBSの設定削除などは未実装)
 - checkfiles: ローカルで利用するスクリプトを生成します。
 - ssh: 各VMにアクセスできます。 例：./hpcbmtenv.sh ssh 1: コンピュートノード#1にSSHアクセスします。

## 一般的な利用方法
0. updatensg コマンド: スクリプト実行ノードのグローバルIPを利用してセキュリティグループを設定します。
1. create コマンド: コンピュートノードを作成します。
2. addlogin コマンド: login, PBSノードを作成します。
3. 任意：privatenw コマンド: コンピュートノード、PBSノードからグローバルIPアドレスを除きます

