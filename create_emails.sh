#!/bin/bash

# 读取用户输入
read -p "请输入邮箱后缀（例如yourdomain.com）：" domain_suffix
read -p "请输入密码：" password
read -p "请输入要生成的邮箱数量：" count

# 创建输出文件
output_file="email_list.txt"
> "$output_file"  # 清空或创建文件

# 在容器内部创建邮箱账户
for ((i=1; i<=count; i++)); do
    # 生成随机用户名长度（6到8位）
    username_length=$(shuf -i 6-8 -n 1)
    
    # 生成随机用户名，包含小写字母和数字
    username=$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w "$username_length" | head -n 1)
    
    full_email="${username}@${domain_suffix}"
    
    # 创建邮箱账户，使用 expect 处理交互式密码输入
    expect -c "
        spawn docker exec -it 1Panel-maddy-mail-iHBZ /bin/sh -c \"maddy creds create '${full_email}'\"
        expect \"Enter password for new user:\"
        send \"${password}\r\"
        expect eof
    "
    
    # 将邮箱信息写入文件
    echo "邮箱: ${full_email}, 密码: ${password}" >> "$output_file"
done

echo "邮箱账户创建完成，邮箱列表已保存到 $(pwd)/$output_file"
