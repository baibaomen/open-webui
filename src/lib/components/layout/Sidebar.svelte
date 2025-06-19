<script lang="ts">
	import { toast } from 'svelte-sonner';
	import { v4 as uuidv4 } from 'uuid';

	import { goto } from '$app/navigation';
	import { page } from '$app/stores';
	import {
		user,
		chats,
		settings,
		showSettings,
		chatId,
		tags,
		showSidebar,
		showSearch,
		mobile,
		showArchivedChats,
		pinnedChats,
		scrollPaginationEnabled,
		currentChatPage,
		temporaryChatEnabled,
		channels,
		socket,
		config,
		isApp
	} from '$lib/stores';
	import { onMount, getContext, tick, onDestroy } from 'svelte';

	const i18n = getContext('i18n');

	import {
		deleteChatById,
		getChatList,
		getAllTags,
		getChatListBySearchText,
		createNewChat,
		getPinnedChatList,
		toggleChatPinnedStatusById,
		getChatPinnedStatusById,
		getChatById,
		updateChatFolderIdById,
		importChat
	} from '$lib/apis/chats';
	import { createNewFolder, getFolders, updateFolderParentIdById } from '$lib/apis/folders';
	import { WEBUI_BASE_URL } from '$lib/constants';

	import ArchivedChatsModal from './Sidebar/ArchivedChatsModal.svelte';
	import UserMenu from './Sidebar/UserMenu.svelte';
	import ChatItem from './Sidebar/ChatItem.svelte';
	import Spinner from '../common/Spinner.svelte';
	import Loader from '../common/Loader.svelte';
	import AddFilesPlaceholder from '../AddFilesPlaceholder.svelte';
	import Folder from '../common/Folder.svelte';
	import Plus from '../icons/Plus.svelte';
	import Tooltip from '../common/Tooltip.svelte';
	import Folders from './Sidebar/Folders.svelte';
	import { getChannels, createNewChannel } from '$lib/apis/channels';
	import ChannelModal from './Sidebar/ChannelModal.svelte';
	import ChannelItem from './Sidebar/ChannelItem.svelte';
	import PencilSquare from '../icons/PencilSquare.svelte';
	import Home from '../icons/Home.svelte';
	import MagnifyingGlass from '../icons/MagnifyingGlass.svelte';
	import SearchModal from './SearchModal.svelte';

	const BREAKPOINT = 768;

	let navElement;
	let shiftKey = false;
	let search = '';
	let selectedChatId = null;
	let showDropdown = false;
	let showPinnedChat = true;
	let showChatsSection = true;
	let activeNavItem = 'home'; // 'home', 'newchat', 'chats', 'search'

	let showCreateChannel = false;

	// Pagination variables
	let chatListLoading = false;
	let allChatsLoaded = false;

	let folders = {};
	let newFolderId = null;

	let filteredChatList = [];

	$:filteredChatList = $chats?.filter((chat) => {
		if (search === '') {
			return true;
		} else {
			let title = chat.title.toLowerCase();
			const query = search.toLowerCase();

			let contentMatches = false;
			// Access the messages within chat.chat.messages
			if (chat.chat && chat.chat.messages && Array.isArray(chat.chat.messages)) {
				contentMatches = chat.chat.messages.some((message) => {
					// Check if message.content exists and includes the search query
					return message.content && message.content.toLowerCase().includes(query);
				});
			}

			return title.includes(query) || contentMatches;
		}
	})

	// 根据当前路径确定活动的导航项
	$: {
		const pathname = $page.url.pathname;
		if (pathname === '/' || pathname.startsWith('/c/')) {
			activeNavItem = 'chats';
		} else if (pathname.startsWith('/workspace')) {
			activeNavItem = 'workspace';
		} else if (pathname.startsWith('/notes')) {
			activeNavItem = 'notes';
		} else if (pathname.startsWith('/playground')) {
			activeNavItem = 'playground';
		} else {
			activeNavItem = 'home';
		}
	}

	// 统一的菜单激活状态判断函数
	const isMenuActive = (menuType: 'home' | 'newchat' | 'chats') => {
		const pathname = $page.url.pathname;
		
		switch (menuType) {
			case 'home':
				// 首页：当路径是 '/' 且没有有效的 chatId，或者路径是 '/home' 时激活
				return (pathname === '/' && (!$chatId || $chatId === '')) || pathname === '/home';
			
			case 'newchat':
				// 新会话：作为操作按钮，不需要激活状态
				return false;
			
			case 'chats':
				// 会话历史：当路径是 '/' 且有有效的 chatId，或者路径以 '/c/' 开头时激活
				return (pathname === '/' && $chatId && $chatId !== '') || pathname.startsWith('/c/');
			
			default:
				return false;
		}
	};

	// 反应式计算激活状态，确保及时更新
	$: isHomeActive = ($page.url.pathname === '/' && (!$chatId || $chatId === '')) || $page.url.pathname === '/home';
	$: isChatsActive = ($page.url.pathname === '/' && $chatId && $chatId !== '') || $page.url.pathname.startsWith('/c/');

	const initFolders = async () => {
		const folderList = await getFolders(localStorage.token).catch((error) => {
			toast.error(`${error}`);
			return [];
		});

		folders = {};

		// First pass: Initialize all folder entries
		for (const folder of folderList) {
			// Ensure folder is added to folders with its data
			folders[folder.id] = { ...(folders[folder.id] || {}), ...folder };

			if (newFolderId && folder.id === newFolderId) {
				folders[folder.id].new = true;
				newFolderId = null;
			}
		}

		// Second pass: Tie child folders to their parents
		for (const folder of folderList) {
			if (folder.parent_id) {
				// Ensure the parent folder is initialized if it doesn't exist
				if (!folders[folder.parent_id]) {
					folders[folder.parent_id] = {}; // Create a placeholder if not already present
				}

				// Initialize childrenIds array if it doesn't exist and add the current folder id
				folders[folder.parent_id].childrenIds = folders[folder.parent_id].childrenIds
					? [...folders[folder.parent_id].childrenIds, folder.id]
					: [folder.id];

				// Sort the children by updated_at field
				folders[folder.parent_id].childrenIds.sort((a, b) => {
					return folders[b].updated_at - folders[a].updated_at;
				});
			}
		}
	};

	const createFolder = async (name = 'Untitled') => {
		if (name === '') {
			toast.error($i18n.t('Folder name cannot be empty.'));
			return;
		}

		const rootFolders = Object.values(folders).filter((folder) => folder.parent_id === null);
		if (rootFolders.find((folder) => folder.name.toLowerCase() === name.toLowerCase())) {
			// If a folder with the same name already exists, append a number to the name
			let i = 1;
			while (
				rootFolders.find((folder) => folder.name.toLowerCase() === `${name} ${i}`.toLowerCase())
			) {
				i++;
			}

			name = `${name} ${i}`;
		}

		// Add a dummy folder to the list to show the user that the folder is being created
		const tempId = uuidv4();
		folders = {
			...folders,
			tempId: {
				id: tempId,
				name: name,
				created_at: Date.now(),
				updated_at: Date.now()
			}
		};

		const res = await createNewFolder(localStorage.token, name).catch((error) => {
			toast.error(`${error}`);
			return null;
		});

		if (res) {
			newFolderId = res.id;
			await initFolders();
		}
	};

	const initChannels = async () => {
		await channels.set(await getChannels(localStorage.token));
	};

	const initChatList = async () => {
		// Reset pagination variables
		tags.set(await getAllTags(localStorage.token));
		pinnedChats.set(await getPinnedChatList(localStorage.token));
		initFolders();

		currentChatPage.set(1);
		allChatsLoaded = false;

		await chats.set(await getChatList(localStorage.token, $currentChatPage));

		// Enable pagination
		scrollPaginationEnabled.set(true);
	};

	const loadMoreChats = async () => {
		chatListLoading = true;

		currentChatPage.set($currentChatPage + 1);

		let newChatList = [];

		newChatList = await getChatList(localStorage.token, $currentChatPage);

		// once the bottom of the list has been reached (no results) there is no need to continue querying
		allChatsLoaded = newChatList.length === 0;
		await chats.set([...($chats ? $chats : []), ...newChatList]);

		chatListLoading = false;
	};

	const importChatHandler = async (items, pinned = false, folderId = null) => {
		console.log('importChatHandler', items, pinned, folderId);
		for (const item of items) {
			console.log(item);
			if (item.chat) {
				await importChat(localStorage.token, item.chat, item?.meta ?? {}, pinned, folderId);
			}
		}

		initChatList();
	};

	const inputFilesHandler = async (files) => {
		console.log(files);

		for (const file of files) {
			const reader = new FileReader();
			reader.onload = async (e) => {
				const content = e.target.result;

				try {
					const chatItems = JSON.parse(content);
					importChatHandler(chatItems);
				} catch {
					toast.error($i18n.t(`Invalid file format.`));
				}
			};

			reader.readAsText(file);
		}
	};

	const tagEventHandler = async (type, tagName, chatId) => {
		console.log(type, tagName, chatId);
		if (type === 'delete') {
			initChatList();
		} else if (type === 'add') {
			initChatList();
		}
	};

	let draggedOver = false;

	const onDragOver = (e) => {
		e.preventDefault();

		// Check if a file is being draggedOver.
		if (e.dataTransfer?.types?.includes('Files')) {
			draggedOver = true;
		} else {
			draggedOver = false;
		}
	};

	const onDragLeave = () => {
		draggedOver = false;
	};

	const onDrop = async (e) => {
		e.preventDefault();
		console.log(e); // Log the drop event

		// Perform file drop check and handle it accordingly
		if (e.dataTransfer?.files) {
			const inputFiles = Array.from(e.dataTransfer?.files);

			if (inputFiles && inputFiles.length > 0) {
				console.log(inputFiles); // Log the dropped files
				inputFilesHandler(inputFiles); // Handle the dropped files
			}
		}

		draggedOver = false; // Reset draggedOver status after drop
	};

	let touchstart;
	let touchend;

	function checkDirection() {
		const screenWidth = window.innerWidth;
		const swipeDistance = Math.abs(touchend.screenX - touchstart.screenX);
		if (touchstart.clientX < 40 && swipeDistance >= screenWidth / 8) {
			if (touchend.screenX < touchstart.screenX) {
				showSidebar.set(false);
			}
			if (touchend.screenX > touchstart.screenX) {
				showSidebar.set(true);
			}
		}
	}

	const onTouchStart = (e) => {
		touchstart = e.changedTouches[0];
		console.log(touchstart.clientX);
	};

	const onTouchEnd = (e) => {
		touchend = e.changedTouches[0];
		checkDirection();
	};

	const onKeyDown = (e) => {
		if (e.key === 'Shift') {
			shiftKey = true;
		}
	};

	const onKeyUp = (e) => {
		if (e.key === 'Shift') {
			shiftKey = false;
		}
	};

	const onFocus = () => {};

	const onBlur = () => {
		shiftKey = false;
		selectedChatId = null;
	};

	onMount(async () => {
		showPinnedChat = localStorage?.showPinnedChat ? localStorage.showPinnedChat === 'true' : true;
		showChatsSection = localStorage?.showChatsSection ? localStorage.showChatsSection === 'true' : true;

		mobile.subscribe((value) => {
			if ($showSidebar && value) {
				showSidebar.set(false);
			}

			if ($showSidebar && !value) {
				const navElement = document.getElementsByTagName('nav')[0];
				if (navElement) {
					navElement.style['-webkit-app-region'] = 'drag';
				}
			}

			if (!$showSidebar && !value) {
				showSidebar.set(true);
			}
		});

		showSidebar.set(!$mobile ? localStorage.sidebar === 'true' : false);
		showSidebar.subscribe((value) => {
			localStorage.sidebar = value;

			// nav element is not available on the first render
			const navElement = document.getElementsByTagName('nav')[0];

			if (navElement) {
				if ($mobile) {
					if (!value) {
						navElement.style['-webkit-app-region'] = 'drag';
					} else {
						navElement.style['-webkit-app-region'] = 'no-drag';
					}
				} else {
					navElement.style['-webkit-app-region'] = 'drag';
				}
			}
		});

		await initChannels();
		await initChatList();

		window.addEventListener('keydown', onKeyDown);
		window.addEventListener('keyup', onKeyUp);

		window.addEventListener('touchstart', onTouchStart);
		window.addEventListener('touchend', onTouchEnd);

		window.addEventListener('focus', onFocus);
		window.addEventListener('blur-sm', onBlur);

		const dropZone = document.getElementById('sidebar');

		dropZone?.addEventListener('dragover', onDragOver);
		dropZone?.addEventListener('drop', onDrop);
		dropZone?.addEventListener('dragleave', onDragLeave);
	});

	onDestroy(() => {
		window.removeEventListener('keydown', onKeyDown);
		window.removeEventListener('keyup', onKeyUp);

		window.removeEventListener('touchstart', onTouchStart);
		window.removeEventListener('touchend', onTouchEnd);

		window.removeEventListener('focus', onFocus);
		window.removeEventListener('blur-sm', onBlur);

		const dropZone = document.getElementById('sidebar');

		dropZone?.removeEventListener('dragover', onDragOver);
		dropZone?.removeEventListener('drop', onDrop);
		dropZone?.removeEventListener('dragleave', onDragLeave);
	});
</script>

<ArchivedChatsModal
	bind:show={$showArchivedChats}
	on:change={async () => {
		await initChatList();
	}}
/>

<ChannelModal
	bind:show={showCreateChannel}
	onSubmit={async ({ name, access_control }) => {
		const res = await createNewChannel(localStorage.token, {
			name: name,
			access_control: access_control
		}).catch((error) => {
			toast.error(`${error}`);
			return null;
		});

		if (res) {
			$socket.emit('join-channels', { auth: { token: $user?.token } });
			await initChannels();
			showCreateChannel = false;
		}
	}}
/>

<!-- svelte-ignore a11y-no-static-element-interactions -->

{#if $showSidebar}
	<div
		class=" {$isApp
			? ' ml-[4.5rem] md:ml-0'
			: ''} fixed md:hidden z-40 top-0 right-0 left-0 bottom-0 bg-black/60 w-full min-h-screen h-screen flex justify-center overflow-hidden overscroll-contain"
		on:mousedown={() => {
			showSidebar.set(!$showSidebar);
		}}
	/>
{/if}

<SearchModal
	bind:show={$showSearch}
	onClose={() => {
		if ($mobile) {
			showSidebar.set(false);
		}
	}}
/>

<div
	bind:this={navElement}
	id="sidebar"
	class="h-screen max-h-[100dvh] min-h-screen select-none {$showSidebar
		? 'md:relative w-[180px] max-w-[180px]'
		: 'md:relative w-[100px] max-w-[100px]'} {$isApp
		? `ml-[4.5rem] md:ml-0 `
		: 'transition-all duration-300 ease-in-out'} text-white text-sm fixed z-50 top-0 left-0 overflow-x-hidden
        "
	data-state={$showSidebar}
>
	<div
		class="py-2 my-auto flex flex-col justify-between h-screen max-h-[100dvh] {$showSidebar
			? 'w-[180px]'
			: 'w-[100px]'} overflow-x-hidden z-50"
	>
		<!-- 顶部Logo区域 -->
		<div class="px-2 flex flex-col items-center space-y-4">
			<!-- Logo -->
			<div class="flex items-center justify-center pt-6 pb-4">
				<img
					crossorigin="anonymous"
					src="{WEBUI_BASE_URL}/static/favicon.png"
					class="size-11 rounded-full"
					alt="logo"
				/>
				{#if $showSidebar}
					<div class="ml-3 text-2xl font-bold text-white">agent</div>
				{/if}
			</div>

			<!-- 导航菜单 -->
			<div class="flex flex-col space-y-2 w-full">
				<!-- 首页 -->
				<a
					class="flex items-center {$showSidebar ? 'justify-start px-4' : 'justify-center px-2'} py-3 rounded-xl transition group {isHomeActive ? 'font-bold' : 'hover:font-bold'}"
					href="/"
					on:click={async () => {
						selectedChatId = null;
						// 清空 chatId 以确保首页激活状态正确
						chatId.set('');
						await goto('/');
						const newChatButton = document.getElementById('new-chat-button');
						setTimeout(() => {
							newChatButton?.click();
							if ($mobile) {
								showSidebar.set(false);
							}
						}, 0);
					}}
					draggable="false"
				>
					<div class={`p-1.5 self-center ${isHomeActive ? 'text-orange-600 bg-white rounded-lg' : ''}`}>
						<img src={isHomeActive ? '/home-active.png' : '/home.png'} class="size-6" alt="首页" />
					</div>
					{#if $showSidebar}
						<div class="ml-3">{$i18n.t('首页')}</div>
					{/if}
				</a>

				<!-- 新会话 -->
				<a
				id="sidebar-new-chat-button"
				class="flex items-center {$showSidebar ? 'justify-start px-4' : 'justify-center px-2'} py-3 rounded-xl transition group hover:font-bold"
				href="/"
				draggable="false"
				on:click={async (e) => {
					e.preventDefault();
					selectedChatId = null;
					
					try {
						// 创建新会话
						const newChat = await createNewChat(localStorage.token, {
							title: `新会话`,
							models: $settings?.models ?? [''],
							system: $settings?.system ?? undefined,
							options: {},
							history: {
								messages: {},
								currentId: null
							},
							messages: [],
							timestamp: Date.now()
						});

						if (newChat) {
							// 刷新会话列表
							await initChatList();
							
							// 跳转到新创建的会话
							await goto(`/c/${newChat.id}`);
							
							// 设置当前会话ID
							chatId.set(newChat.id);
							
							toast.success($i18n.t('新会话已创建'));
							
							if ($mobile) {
								showSidebar.set(false);
							}
						}
					} catch (error) {
						console.error('创建新会话失败:', error);
						toast.error($i18n.t('创建新会话失败，请重试'));
						
						// 如果创建失败，仍然跳转到主页开始新会话
						await goto('/');
						const newChatButton = document.getElementById('new-chat-button');
						setTimeout(() => {
							newChatButton?.click();
							if ($mobile) {
								showSidebar.set(false);
							}
						}, 0);
					}
				}}
			>
					<div class="p-1.5 self-center">
						<img src="/createmessage.png" class="size-6" alt="新会话" />
					</div>
					{#if $showSidebar}
						<div class="ml-3">{$i18n.t('新会话')}</div>
					{/if}
				</a>

				<!-- 会话 -->
				<button
					class="flex items-center {$showSidebar ? 'justify-start px-4' : 'justify-center px-2'} py-3 rounded-xl transition group relative {isChatsActive ? 'font-bold' : 'hover:font-bold'}"
					on:click={() => {
						if ($showSidebar) {
							showChatsSection = !showChatsSection;
							localStorage.setItem('showChatsSection', showChatsSection.toString());
						}
					}}
				>
					<div class={`p-1.5 self-center ${isChatsActive ? 'text-orange-600 bg-white rounded-lg' : ''}`}>
						<img src={isChatsActive ? '/message-active.png' : '/message.png'} class="size-6" alt="历史会话" />
					</div>
					{#if $showSidebar}
						<div class="ml-3">{$i18n.t('历史会话')}</div>
						<div class="ml-auto">
							<svg
								xmlns="http://www.w3.org/2000/svg"
								fill="none"
								viewBox="0 0 24 24"
								stroke-width="2"
								stroke="currentColor"
								class="size-3 transition-transform {showChatsSection ? 'rotate-180' : ''}"
							>
								<path
									stroke-linecap="round"
									stroke-linejoin="round"
									d="m19.5 8.25-7.5 7.5-7.5-7.5"
								/>
							</svg>
						</div>
					{/if}
				</button>
			</div>
		</div>

		<!-- 会话内容区域 -->
		{#if $showSidebar && showChatsSection}
			<div
				class="relative flex flex-col flex-1 overflow-y-auto overflow-x-hidden px-2 {$temporaryChatEnabled
					? 'opacity-20'
					: ''}"
			>
				{#if $config?.features?.enable_channels && ($user?.role === 'admin' || $channels.length > 0)}
					<div class="mt-2">
						<div class="flex items-center justify-between px-2 py-1">
							<span class="text-xs font-medium text-white opacity-80">{$i18n.t('Channels')}</span>
							{#if $user?.role === 'admin'}
								<button
									class="text-white opacity-60 hover:opacity-100 transition"
									on:click={async () => {
										await tick();
										setTimeout(() => {
											showCreateChannel = true;
										}, 0);
									}}
								>
									<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="2" stroke="currentColor" class="size-4">
										<path stroke-linecap="round" stroke-linejoin="round" d="M12 4.5v15m7.5-7.5h-15" />
									</svg>
								</button>
							{/if}
						</div>
						{#each $channels as channel}
							<ChannelItem
								{channel}
								onUpdate={async () => {
									await initChannels();
								}}
							/>
						{/each}
					</div>
				{/if}

				<div class="pl-4">
					{#if $temporaryChatEnabled}
						<div class="absolute z-40 w-full h-full flex justify-center"></div>
					{/if}

					{#if $pinnedChats.length > 0}
						<div class="mt-3">
							<button
								class="flex items-center justify-between w-full px-2 py-1 text-xs font-medium text-white opacity-80 hover:opacity-100 transition"
								on:click={() => {
									showPinnedChat = !showPinnedChat;
									localStorage.setItem('showPinnedChat', showPinnedChat.toString());
								}}
							>
								<span>{$i18n.t('Pinned')}</span>
								<svg
									xmlns="http://www.w3.org/2000/svg"
									fill="none"
									viewBox="0 0 24 24"
									stroke-width="2"
									stroke="currentColor"
									class="size-3 transition-transform {showPinnedChat ? 'rotate-180' : ''}"
								>
									<path stroke-linecap="round" stroke-linejoin="round" d="m19.5 8.25-7.5 7.5-7.5-7.5" />
								</svg>
							</button>
							{#if showPinnedChat}
								<div class="ml-2 mt-1 space-y-1">
									{#each $pinnedChats as chat, idx}
										<ChatItem
											className=""
											id={chat.id}
											title={chat.title}
											{shiftKey}
											selected={selectedChatId === chat.id}
											on:select={() => {
												selectedChatId = chat.id;
											}}
											on:unselect={() => {
												selectedChatId = null;
											}}
											on:change={async () => {
												initChatList();
											}}
											on:tag={(e) => {
												const { type, name } = e.detail;
												tagEventHandler(type, name, chat.id);
											}}
										/>
									{/each}
								</div>
							{/if}
						</div>
					{/if}

					{#if folders}
						<div class="mt-3">
							<Folders
								{folders}
								on:import={(e) => {
									const { folderId, items } = e.detail;
									importChatHandler(items, false, folderId);
								}}
								on:update={async (e) => {
									initChatList();
								}}
								on:change={async () => {
									initChatList();
								}}
							/>
						</div>
					{/if}

					<div class="flex-1 flex flex-col overflow-y-auto scrollbar-hidden mt-3">
						<div class="space-y-1">
							{#if $chats}
								{#each $chats as chat, idx}
								{#if idx === 0 || (idx > 0 && chat.time_range !== filteredChatList[idx - 1].time_range)}
								<div
									class="w-full pl-2.5 text-xs text-white opacity-80 font-medium {idx === 0
										? ''
										: 'pt-5'} pb-0.5"
								>
									{$i18n.t(chat.time_range)}
									<!-- localisation keys for time_range to be recognized from the i18next parser (so they don't get automatically removed):
									{$i18n.t('Today')}
									{$i18n.t('Yesterday')}
									{$i18n.t('Previous 7 days')}
									{$i18n.t('Previous 30 days')}
									{$i18n.t('January')}
									{$i18n.t('February')}
									{$i18n.t('March')}
									{$i18n.t('April')}
									{$i18n.t('May')}
									{$i18n.t('June')}
									{$i18n.t('July')}
									{$i18n.t('August')}
									{$i18n.t('September')}
									{$i18n.t('October')}
									{$i18n.t('November')}
									{$i18n.t('December')}
									-->
								</div>
							{/if}

									<ChatItem
										className=""
										id={chat.id}
										title={chat.title}
										{shiftKey}
										selected={selectedChatId === chat.id}
										on:select={() => {
											selectedChatId = chat.id;
										}}
										on:unselect={() => {
											selectedChatId = null;
										}}
										on:change={async () => {
											initChatList();
										}}
										on:tag={(e) => {
											const { type, name } = e.detail;
											tagEventHandler(type, name, chat.id);
										}}
									/>
								{/each}

								{#if $scrollPaginationEnabled && !allChatsLoaded}
									<Loader
										on:visible={(e) => {
											if (!chatListLoading) {
												loadMoreChats();
											}
										}}
									>
										<div
											class="w-full flex justify-center py-1 text-xs animate-pulse items-center gap-2 text-white opacity-60"
										>
											<Spinner className=" size-4" />
											<div class=" ">Loading...</div>
										</div>
									</Loader>
								{/if}
							{:else}
								<div class="w-full flex justify-center py-1 text-xs animate-pulse items-center gap-2 text-white opacity-60">
									<Spinner className=" size-4" />
									<div class=" ">Loading...</div>
								</div>
							{/if}
						</div>
					</div>
				</div>
			</div>
		{/if}

		<!-- 底部用户菜单 -->
		<div class="px-2">
			<div class="flex justify-center font-primary mb-4">
				<img
				class="w-[100px] h-7"
				src="/assets/images/SketchPn_5.png"
			  />
			</div>
		</div>
	</div>
</div>

<style>
	.scrollbar-hidden:active::-webkit-scrollbar-thumb,
	.scrollbar-hidden:focus::-webkit-scrollbar-thumb,
	.scrollbar-hidden:hover::-webkit-scrollbar-thumb {
		visibility: visible;
	}
	.scrollbar-hidden::-webkit-scrollbar-thumb {
		visibility: hidden;
	}
</style>
