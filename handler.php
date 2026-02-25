<?php
include("index.php");
$update = json_decode(file_get_contents('php://input'));

$userid = $update->CustomField;
$title = $update->Title;
$code = $update->Code;
$name = $update->Name;
$amount = $update->Amount;
$coin = file_get_contents("data/users/".$userid."/coin.txt");

SendMessage($admin,"شما یک پرداخت با مبلغ $amount داشتید
شناسه کاربر :‌ $userid");
SendMessage($userid,"پرداخت شما موفق بود
 لطفا چند لحظه صبر کنید");
  
if ($title == "20Gem") {
	SendMessage($userid,"شما با موفقیت مبلغ $amount را پرداخت کردید
و 20 الماس دریافت کردید");
$m = $coin + 20;
	save("data/users/".$userid."/coin.txt",$m);
}

elseif ($title == "40Gem") {
	SendMessage($userid,"شما با موفقیت مبلغ $amount را پرداخت کردید
و 40 الماس دریافت کردید");
$m = $coin + 40;
	save("data/users/".$userid."/coin.txt",$m);
}
  
elseif ($title == "80Gem") {
	SendMessage($userid,"شما با موفقیت مبلغ $amount را پرداخت کردید
و 80 الماس دریافت کردید");
$m = $coin + 80;
	save("data/users/".$userid."/coin.txt",$m);
}
?>